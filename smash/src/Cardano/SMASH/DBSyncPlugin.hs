{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.SMASH.DBSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  -- * For future testing
  , insertDefaultBlock
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace                         (Trace,
                                                           logError, logInfo)

import           Control.Monad.Logger                     (LoggingT)
import           Control.Monad.Trans.Except.Extra         (firstExceptT,
                                                           newExceptT,
                                                           runExceptT)
import           Control.Monad.Trans.Reader               (ReaderT)

import           Cardano.SMASH.DB                         (DBFail (..),
                                                           DataLayer (..))
import           Cardano.SMASH.Offline                    (fetchInsertNewPoolMetadata)
import           Cardano.SMASH.Types                      (PoolId (..),
                                                           PoolMetadataHash (..),
                                                           PoolUrl (..))

import qualified Cardano.Chain.Block                      as Byron

import qualified Data.ByteString.Base16                   as B16

import           Database.Persist.Sql                     (IsolationLevel (..),
                                                           SqlBackend,
                                                           transactionSaveWithIsolation)

import qualified Cardano.SMASH.DBSync.Db.Insert           as DB
import qualified Cardano.SMASH.DBSync.Db.Schema           as DB

import           Cardano.DbSync.Config.Types
import           Cardano.DbSync.Error
import           Cardano.DbSync.Types                     as DbSync

import           Cardano.DbSync.LedgerState

import           Cardano.DbSync                           (DbSyncNodePlugin (..))
import           Cardano.DbSync.Util


import qualified Cardano.DbSync.Era.Byron.Util            as Byron
import qualified Cardano.DbSync.Era.Shelley.Generic       as Shelley

import           Cardano.Slotting.Block                   (BlockNo (..))
import           Cardano.Slotting.Slot                    (EpochNo (..),
                                                           SlotNo (..))

import           Shelley.Spec.Ledger.BaseTypes            (strictMaybeToMaybe)
import qualified Shelley.Spec.Ledger.BaseTypes            as Shelley
import qualified Shelley.Spec.Ledger.TxBody               as Shelley

import           Ouroboros.Consensus.Byron.Ledger         (ByronBlock (..))

import           Ouroboros.Consensus.Cardano.Block        (HardForkBlock (..),
                                                           StandardShelley)

import qualified Cardano.DbSync.Era.Shelley.Generic       as Generic

-- |Pass in the @DataLayer@.
poolMetadataDbSyncNodePlugin :: DataLayer -> DbSyncNodePlugin
poolMetadataDbSyncNodePlugin dataLayer =
  DbSyncNodePlugin
    { plugOnStartup = []
    , plugInsertBlock = [insertDefaultBlock dataLayer]
    , plugRollbackBlock = []
    }

-- For information on what era we are in.
data BlockName
    = Shelley
    | Allegra
    | Mary
    deriving (Eq, Show)

-- |TODO(KS): We need to abstract over these blocks so we can test this functionality
-- separatly from the actual blockchain, using tests only.
insertDefaultBlock
    :: DataLayer
    -> Trace IO Text
    -> DbSyncEnv
    -> LedgerStateVar
    -> BlockDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertDefaultBlock dataLayer tracer env ledgerStateVar (BlockDetails cblk details) = do
  -- Calculate the new ledger state to pass to the DB insert functions but do not yet
  -- update ledgerStateVar.
  lStateSnap <- liftIO $ applyBlock env ledgerStateVar cblk
  res <- case cblk of
            BlockByron blk -> do
              insertByronBlock tracer blk details
            BlockShelley blk -> do
              insertShelleyBlock Shelley dataLayer tracer env (Generic.fromShelleyBlock blk) lStateSnap details
            BlockAllegra blk -> do
              insertShelleyBlock Allegra dataLayer tracer env (Generic.fromAllegraBlock blk) lStateSnap details
            BlockMary blk -> do
              insertShelleyBlock Mary dataLayer tracer env (Generic.fromMaryBlock blk) lStateSnap details

  -- Now we update it in ledgerStateVar and (possibly) store it to disk.
  liftIO $ saveLedgerState (envLedgerStateDir env) ledgerStateVar
                (lssState lStateSnap) (isSyncedWithinSeconds details 60)

  pure res


-- We don't care about Byron, no pools there
insertByronBlock
    :: Trace IO Text
    -> ByronBlock
    -> DbSync.SlotDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertByronBlock tracer blk _details = do
  case byronBlockRaw blk of
    Byron.ABOBBlock byronBlock -> do
        let slotNum = Byron.slotNumber byronBlock
        -- Output in intervals, don't add too much noise to the output.
        when (slotNum `mod` 5000 == 0) $
            liftIO . logInfo tracer $ "Byron block, slot: " <> show slotNum
    Byron.ABOBBoundary {} -> pure ()

  return $ Right ()

-- Here we insert pools.
insertShelleyBlock
    :: BlockName
    -> DataLayer
    -> Trace IO Text
    -> DbSyncEnv
    -> Generic.Block
    -> LedgerStateSnapshot
    -> SlotDetails
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertShelleyBlock blockName dataLayer tracer env blk _lStateSnap details = do

  runExceptT $ do

    -- TODO(KS): Move to DataLayer.
    _blkId <- lift . DB.insertBlock $
                  DB.Block
                    { DB.blockHash = Shelley.blkHash blk
                    , DB.blockEpochNo = Just $ unEpochNo (sdEpochNo details)
                    , DB.blockSlotNo = Just $ unSlotNo (Generic.blkSlotNo blk)
                    , DB.blockBlockNo = Just $ unBlockNo (Generic.blkBlockNo blk)
                    }

    zipWithM_ (insertTx dataLayer tracer env) [0 .. ] (Shelley.blkTxs blk)

    liftIO $ do
      let epoch = unEpochNo (sdEpochNo details)
          slotWithinEpoch = unEpochSlot (sdEpochSlot details)
          blockNumber = Generic.blkBlockNo blk

      when (slotWithinEpoch `mod` 1000 == 0) $
        logInfo tracer $ mconcat
          [ "Insert '", show blockName
          , "' block pool info: epoch ", show epoch
          , ", slot ", show slotWithinEpoch
          , ", block ", show blockNumber
          ]

    lift $ transactionSaveWithIsolation Serializable

insertTx
    :: (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> DbSyncEnv
    -> Word64
    -> Generic.Tx
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertTx dataLayer tracer env _blockIndex tx =
    mapM_ (insertCertificate dataLayer tracer env) $ Generic.txCertificates tx

insertCertificate
    :: (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> DbSyncEnv
    -> Generic.TxCertificate
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertCertificate dataLayer tracer _env (Generic.TxCertificate _idx cert) =
  case cert of
    Shelley.DCertDeleg _deleg ->
        liftIO $ logInfo tracer "insertCertificate: DCertDeleg"
    Shelley.DCertPool pool -> insertPoolCert dataLayer tracer pool
    Shelley.DCertMir _mir ->
        liftIO $ logInfo tracer "insertCertificate: DCertMir"
    Shelley.DCertGenesis _gen ->
        liftIO $ logError tracer "insertCertificate: Unhandled DCertGenesis certificate"

insertPoolCert
    :: (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> Shelley.PoolCert StandardShelley
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert dataLayer tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> insertPoolRegister dataLayer tracer pParams

    -- RetirePool (KeyHash 'StakePool era) _ = PoolId
    Shelley.RetirePool poolPubKey _epochNum -> do
        let poolIdHash = B16.encode . Generic.unKeyHashRaw $ poolPubKey
        let poolId = PoolId . decodeUtf8 $ poolIdHash

        liftIO . logInfo tracer $ "Retiring pool with poolId: " <> show poolId

        let addRetiredPool = dlAddRetiredPool dataLayer

        eitherPoolId <- liftIO $ addRetiredPool poolId

        case eitherPoolId of
            Left err -> liftIO . logError tracer $ "Error adding retiring pool: " <> show err
            Right poolId' -> liftIO . logInfo tracer $ "Added retiring pool with poolId: " <> show poolId'

insertPoolRegister
    :: forall m. (MonadIO m)
    => DataLayer
    -> Trace IO Text
    -> Shelley.PoolParams StandardShelley
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolRegister dataLayer tracer params = do
  let poolIdHash = B16.encode . Generic.unKeyHashRaw $ Shelley._poolId params
  let poolId = PoolId . decodeUtf8 $ poolIdHash

  liftIO . logInfo tracer $ "Inserting pool register with pool id: " <> decodeUtf8 poolIdHash
  case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do

        liftIO . logInfo tracer $ "Inserting metadata."
        let metadataUrl = PoolUrl . Shelley.urlToText $ Shelley._poolMDUrl md
        let metadataHash = PoolMetadataHash . decodeUtf8 . B16.encode $ Shelley._poolMDHash md

        let addMetaDataReference = dlAddMetaDataReference dataLayer

        -- We need to map this to ExceptT
        refId <- firstExceptT (\(e :: DBFail) -> NEError $ show e) . newExceptT . liftIO $
            addMetaDataReference poolId metadataUrl metadataHash

        liftIO $ fetchInsertNewPoolMetadata dataLayer tracer refId poolId md

        liftIO . logInfo tracer $ "Metadata inserted."

    Nothing -> pure ()

  liftIO . logInfo tracer $ "Inserted pool register."
  pure ()

