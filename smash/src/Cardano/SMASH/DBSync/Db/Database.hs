{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE NoImplicitPrelude    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Cardano.SMASH.DBSync.Db.Database
  ( DbAction (..)
  , DbActionQueue (..)
  , lengthDbActionQueue
  , newDbActionQueue
  , runDbStartup
  , runDbThread
  , writeDbActionQueue
  ) where

import           Cardano.BM.Trace                       (Trace, logDebug,
                                                         logError, logInfo)
import qualified Cardano.Chain.Block                    as Ledger
import           Cardano.Prelude

import           Control.Monad.Logger                   (LoggingT)
import           Control.Monad.Trans.Except.Extra       (left, newExceptT,
                                                         runExceptT)

import           Cardano.Slotting.Slot                  (SlotNo)

import qualified Cardano.SMASH.DB                       as DB

import qualified Cardano.DbSync.Era.Byron.Util          as Byron
import           Cardano.DbSync.Config
import           Cardano.DbSync.DbAction
import           Cardano.DbSync.Error
import           Cardano.DbSync.LedgerState
import           Cardano.DbSync.Plugin
import           Cardano.DbSync.Types
import           Cardano.DbSync.Util

import           Database.Persist.Sql                   (SqlBackend)

import           Ouroboros.Consensus.Byron.Ledger       (ByronBlock (..))
import           Ouroboros.Consensus.Cardano.Block      (HardForkBlock (..))

-- TODO(KS): This whole module is suspect for deletion. I have no clue why there
-- are so many different things in one module.

data NextState
  = Continue
  | Done
  deriving Eq

-- TODO(KS): Do we even need this? What is this?
runDbStartup :: DbSyncNodePlugin -> Trace IO Text -> IO ()
runDbStartup plugin trce =
  DB.runDbAction (Just trce) $
    mapM_ (\action -> action trce) $ plugOnStartup plugin

-- TODO(KS): Needs a @DataLayer@.
-- TODO(KS): Metrics layer!
runDbThread
    :: Trace IO Text
    -> DbSyncEnv
    -> DbSyncNodePlugin
    -> DbActionQueue
    -> LedgerStateVar
    -> IO ()
runDbThread trce env plugin queue ledgerStateVar = do
    logInfo trce "Running DB thread"
    logException trce "runDBThread: " loop
    logInfo trce "Shutting down DB thread"
  where
    loop = do
      xs <- blockingFlushDbActionQueue queue

      when (length xs > 1) $ do
        logDebug trce $ "runDbThread: " <> textShow (length xs) <> " blocks"

      eNextState <- runExceptT $ runActions trce env plugin ledgerStateVar xs

      case eNextState of
        Left err       -> logError trce $ renderDbSyncNodeError err
        Right Continue -> loop
        Right Done     -> pure ()

-- | Run the list of 'DbAction's. Block are applied in a single set (as a transaction)
-- and other operations are applied one-by-one.
runActions
    :: Trace IO Text
    -> DbSyncEnv
    -> DbSyncNodePlugin
    -> LedgerStateVar
    -> [DbAction]
    -> ExceptT DbSyncNodeError IO NextState
runActions trce env plugin ledgerState actions = do
    nextState <- checkDbState trce actions
    if nextState /= Done
      then dbAction Continue actions
      else pure Continue
  where
    dbAction :: NextState -> [DbAction] -> ExceptT DbSyncNodeError IO NextState
    dbAction next [] = pure next
    dbAction Done _ = pure Done
    dbAction Continue xs =
      case spanDbApply xs of
        ([], DbFinish:_) -> do
            pure Done
        ([], DbRollBackToPoint sn:ys) -> do
            runRollbacks trce plugin sn
            liftIO $ loadLedgerState (envLedgerStateDir env) ledgerState sn
            dbAction Continue ys
        (ys, zs) -> do
          insertBlockList trce env ledgerState plugin ys
          if null zs
            then pure Continue
            else dbAction Continue zs

-- TODO(KS): This seems wrong, why do we validate something here?
checkDbState :: Trace IO Text -> [DbAction] -> ExceptT DbSyncNodeError IO NextState
checkDbState trce xs =
    case filter isMainBlockApply (reverse xs) of
      []                        -> pure Continue
      (DbApplyBlock blktip : _) -> validateBlock blktip
      _                         -> pure Continue
  where
    -- We need to seperate base types from new types se we achive separation.
    validateBlock :: BlockDetails -> ExceptT DbSyncNodeError IO NextState
    validateBlock (BlockDetails cblk _) = do
      case cblk of
        BlockByron bblk ->
          case byronBlockRaw bblk of
            Ledger.ABOBBoundary _ -> left $ NEError "checkDbState got a boundary block"
            Ledger.ABOBBlock chBlk -> do
              mDbBlk <- liftIO $ DB.runDbAction (Just trce) $ DB.queryBlockNo (Byron.blockNumber chBlk)
              case mDbBlk of
                Nothing -> pure Continue
                Just dbBlk -> do
                  when (DB.blockHash dbBlk /= Byron.blockHash chBlk) $ do
                    liftIO $ logInfo trce (textShow chBlk)
                    left $ NEBlockMismatch (Byron.blockNumber chBlk) (DB.blockHash dbBlk) (Byron.blockHash chBlk)

                  liftIO . logInfo trce $
                    mconcat [ "checkDbState: Block no ", textShow (Byron.blockNumber chBlk), " present" ]
                  pure Done -- Block already exists, so we are done.

        BlockShelley {} ->
          panic "checkDbState for ShelleyBlock not yet implemented"
        BlockAllegra {} ->
          panic "checkDbState for AllegraBlock not yet implemented"
        BlockMary {} ->
          panic "checkDbState for MaryBlock not yet implemented"


    isMainBlockApply :: DbAction -> Bool
    isMainBlockApply dba =
      case dba of
        DbApplyBlock (BlockDetails cblk _details) ->
          case cblk of
            BlockByron bblk ->
              case byronBlockRaw bblk of
                Ledger.ABOBBlock _    -> True
                Ledger.ABOBBoundary _ -> False
            BlockShelley {} -> False
            BlockAllegra {} -> False
            BlockMary {} -> False
        DbRollBackToPoint {} -> False
        DbFinish -> False

runRollbacks
    :: Trace IO Text
    -> DbSyncNodePlugin
    -> SlotNo
    -> ExceptT DbSyncNodeError IO ()
runRollbacks trce plugin point =
  newExceptT
    . traverseMEither (\ f -> f trce point)
    $ plugRollbackBlock plugin

insertBlockList
    :: Trace IO Text
    -> DbSyncEnv
    -> LedgerStateVar
    -> DbSyncNodePlugin
    -> [BlockDetails]
    -> ExceptT DbSyncNodeError IO ()
insertBlockList trce env ledgerState plugin blks =
  -- Setting this to True will log all 'Persistent' operations which is great
  -- for debugging, but otherwise is *way* too chatty.
  newExceptT
    . DB.runDbAction (Just trce)
    $ traverseMEither insertBlock blks
  where
    insertBlock
        :: BlockDetails
        -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
    insertBlock blkTip =
      traverseMEither (\ f -> f trce env ledgerState blkTip) $ plugInsertBlock plugin

-- | Split the DbAction list into a prefix containing blocks to apply and a postfix.
spanDbApply :: [DbAction] -> ([BlockDetails], [DbAction])
spanDbApply lst =
  case lst of
    (DbApplyBlock bt:xs) -> let (ys, zs) = spanDbApply xs in (bt:ys, zs)
    xs                   -> ([], xs)
