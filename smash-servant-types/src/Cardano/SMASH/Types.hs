{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Cardano.SMASH.Types
    ( ApplicationUser (..)
    , ApplicationUsers (..)
    , stubbedApplicationUsers
    , User
    , UserValidity (..)
    , checkIfUserValid
    -- * Pool info
    , PoolId (..)
    , PoolUrl (..)
    , PoolMetadataHash (..)
    , bytestringToPoolMetaHash
    , PoolMetadataRaw (..)
    , TickerName (..)
    -- * Wrapper
    , PoolName (..)
    , PoolDescription (..)
    , PoolTicker (..)
    , PoolHomepage (..)
    , PoolOfflineMetadata (..)
    , createPoolOfflineMetadata
    , examplePoolOfflineMetadata
    -- * Configuration
    , HealthStatus (..)
    , Configuration (..)
    , defaultConfiguration
    -- * API
    , ApiResult (..)
    -- * HTTP
    , FetchError (..)
    , PoolFetchError (..)
    , TimeStringFormat (..)
    -- * Util
    , DBConversion (..)
    , formatTimeToNormal
    ) where

import           Cardano.Prelude

import           Control.Monad.Fail            (fail)

import           Data.Aeson                    (FromJSON (..), ToJSON (..),
                                                object, withObject, (.:), (.=))
import qualified Data.Aeson                    as Aeson
import           Data.Aeson.Encoding           (unsafeToEncoding)
import qualified Data.Aeson.Types              as Aeson
import           Data.Time.Clock               (UTCTime)
import qualified Data.Time.Clock.POSIX         as Time
import           Data.Time.Format              (defaultTimeLocale, formatTime,
                                                parseTimeM)

import           Data.Swagger                  (NamedSchema (..),
                                                ToParamSchema (..),
                                                ToSchema (..))
import           Data.Text.Encoding            (encodeUtf8Builder)

import           Servant                       (FromHttpApiData (..),
                                                MimeUnrender (..), OctetStream)

import           Cardano.SMASH.DBSync.Db.Error
import           Cardano.SMASH.DBSync.Db.Types

import qualified Data.ByteString.Lazy          as BL
import qualified Data.Text.Encoding            as E

-- | The basic @Configuration@.
data Configuration = Configuration
    { cPortNumber :: !Int
    } deriving (Eq, Show)

defaultConfiguration :: Configuration
defaultConfiguration = Configuration 3100

-- | A list of users with very original passwords.
stubbedApplicationUsers :: ApplicationUsers
stubbedApplicationUsers = ApplicationUsers [ApplicationUser "ksaric" "cirask"]

examplePoolOfflineMetadata :: PoolOfflineMetadata
examplePoolOfflineMetadata =
    PoolOfflineMetadata
        (PoolName "TestPool")
        (PoolDescription "This is a pool for testing")
        (PoolTicker "testp")
        (PoolHomepage "https://iohk.io")

instance ToParamSchema TickerName

instance ToSchema TickerName

instance ToParamSchema PoolId

instance ToSchema PoolId

instance ToParamSchema PoolMetadataHash

-- A data type we use to store user credentials.
data ApplicationUser = ApplicationUser
    { username :: !Text
    , password :: !Text
    } deriving (Eq, Show, Generic)

instance ToJSON ApplicationUser
instance FromJSON ApplicationUser

-- A list of users we use.
newtype ApplicationUsers = ApplicationUsers [ApplicationUser]
    deriving (Eq, Show, Generic)

instance ToJSON ApplicationUsers
instance FromJSON ApplicationUsers

-- | A user we'll grab from the database when we authenticate someone
newtype User = User { userName :: Text }
  deriving (Eq, Show)

-- | This we can leak.
data UserValidity
    = UserValid !User
    | UserInvalid
    deriving (Eq, Show)

-- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
checkIfUserValid :: ApplicationUsers -> ApplicationUser -> UserValidity
checkIfUserValid (ApplicationUsers applicationUsers) applicationUser@(ApplicationUser usernameText _) =
    if applicationUser `elem` applicationUsers
        then (UserValid (User usernameText))
        else UserInvalid

instance FromHttpApiData TickerName where
    parseUrlPiece tickerName = validateTickerName tickerName

-- Currently deserializing from safe types, unwrapping and wrapping it up again.
-- The underlying DB representation is HEX.
instance FromHttpApiData PoolId where
    parseUrlPiece poolId = parsePoolId poolId

instance ToSchema PoolMetadataHash

-- TODO(KS): Temporarily, validation!?
instance FromHttpApiData PoolMetadataHash where
    parseUrlPiece poolMetadataHash = Right $ PoolMetadataHash poolMetadataHash
    --TODO: parse hex or bech32

newtype PoolName = PoolName
    { getPoolName :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolName

newtype PoolDescription = PoolDescription
    { getPoolDescription :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolDescription

newtype PoolTicker = PoolTicker
    { getPoolTicker :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolTicker

newtype PoolHomepage = PoolHomepage
    { getPoolHomepage :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolHomepage

-- | The bit of the pool data off the chain.
data PoolOfflineMetadata = PoolOfflineMetadata
    { pomName        :: !PoolName
    , pomDescription :: !PoolDescription
    , pomTicker      :: !PoolTicker
    , pomHomepage    :: !PoolHomepage
    } deriving (Eq, Show, Ord, Generic)

-- | Smart constructor, just adding one more layer of indirection.
createPoolOfflineMetadata
    :: PoolName
    -> PoolDescription
    -> PoolTicker
    -> PoolHomepage
    -> PoolOfflineMetadata
createPoolOfflineMetadata = PoolOfflineMetadata

-- Required instances
instance FromJSON PoolOfflineMetadata where
    parseJSON = withObject "poolOfflineMetadata" $ \o -> do
        name'           <- parseName o
        description'    <- parseDescription o
        ticker'         <- parseTicker o
        homepage'       <- o .: "homepage"

        return $ PoolOfflineMetadata
            { pomName           = PoolName name'
            , pomDescription    = PoolDescription description'
            , pomTicker         = PoolTicker ticker'
            , pomHomepage       = PoolHomepage homepage'
            }
      where

        -- Copied from https://github.com/input-output-hk/cardano-node/pull/1299

        -- | Parse and validate the stake pool metadata name from a JSON object.
        --
        -- If the name consists of more than 50 characters, the parser will fail.
        parseName :: Aeson.Object -> Aeson.Parser Text
        parseName obj = do
          name <- obj .: "name"
          if length name <= 50
            then pure name
            else fail $
                 "\"name\" must have at most 50 characters, but it has "
              <> show (length name)
              <> " characters."

        -- | Parse and validate the stake pool metadata description from a JSON
        -- object.
        --
        -- If the description consists of more than 255 characters, the parser will
        -- fail.
        parseDescription :: Aeson.Object -> Aeson.Parser Text
        parseDescription obj = do
          description <- obj .: "description"
          if length description <= 255
            then pure description
            else fail $
                 "\"description\" must have at most 255 characters, but it has "
              <> show (length description)
              <> " characters."

        -- | Parse and validate the stake pool ticker description from a JSON object.
        --
        -- If the ticker consists of less than 3 or more than 5 characters, the parser
        -- will fail.
        parseTicker :: Aeson.Object -> Aeson.Parser Text
        parseTicker obj = do
          ticker <- obj .: "ticker"
          let tickerLen = length ticker
          if tickerLen >= 3 && tickerLen <= 5
            then pure ticker
            else fail $
                 "\"ticker\" must have at least 3 and at most 5 "
              <> "characters, but it has "
              <> show (length ticker)
              <> " characters."

-- |We presume the validation is not required the other way around?
instance ToJSON PoolOfflineMetadata where
    toJSON (PoolOfflineMetadata name' description' ticker' homepage') =
        object
            [ "name"            .= getPoolName name'
            , "description"     .= getPoolDescription description'
            , "ticker"          .= getPoolTicker ticker'
            , "homepage"        .= getPoolHomepage homepage'
            ]

instance ToSchema PoolOfflineMetadata

instance MimeUnrender OctetStream PoolMetadataRaw where
    mimeUnrender _ = Right . PoolMetadataRaw . E.decodeUtf8 . BL.toStrict

-- Here we are usingg the unsafe encoding since we already have the JSON format
-- from the database.
instance ToJSON PoolMetadataRaw where
    toJSON (PoolMetadataRaw metadata) = toJSON metadata
    toEncoding (PoolMetadataRaw metadata) = unsafeToEncoding $ encodeUtf8Builder metadata

instance ToSchema PoolMetadataRaw

instance ToSchema DBFail where
  declareNamedSchema _ =
    return $ NamedSchema (Just "DBFail") $ mempty

-- Result wrapper.
newtype ApiResult err a = ApiResult (Either err a)
    deriving (Generic)

instance (ToSchema a, ToSchema err) => ToSchema (ApiResult err a)

instance (ToJSON err, ToJSON a) => ToJSON (ApiResult err a) where

    toJSON (ApiResult (Left dbFail))  = toJSON dbFail
    toJSON (ApiResult (Right result)) = toJSON result

    toEncoding (ApiResult (Left result))  = toEncoding result
    toEncoding (ApiResult (Right result)) = toEncoding result

-- |Fetch error for the HTTP client fetching the pool.
data FetchError
  = FEHashMismatch !PoolId !Text !Text !Text
  | FEDataTooLong !PoolId !Text
  | FEUrlParseFail !PoolId !Text !Text
  | FEJsonDecodeFail !PoolId !Text !Text
  | FEHttpException !PoolId !Text !Text
  | FEHttpResponse !PoolId !Text !Int
  | FEIOException !Text
  | FETimeout !PoolId !Text !Text
  | FEConnectionFailure !PoolId !Text
  deriving (Eq, Generic)

-- |Fetch error for the specific @PoolId@ and the @PoolMetadataHash@.
data PoolFetchError = PoolFetchError !Time.POSIXTime !PoolId !PoolMetadataHash !Text !Word
  deriving (Eq, Show, Generic)

instance ToJSON PoolFetchError where
    toJSON (PoolFetchError time poolId poolHash errorCause retryCount) =
        object
            [ "time"        .= formatTimeToNormal time
            , "utcTime"     .= (show time :: Text)
            , "poolId"      .= getPoolId poolId
            , "poolHash"    .= getPoolMetadataHash poolHash
            , "cause"       .= errorCause
            , "retryCount"  .= retryCount
            ]

instance ToSchema PoolFetchError

formatTimeToNormal :: Time.POSIXTime -> Text
formatTimeToNormal = toS . formatTime defaultTimeLocale "%d.%m.%Y. %T" . Time.posixSecondsToUTCTime

-- |Specific time string format.
newtype TimeStringFormat = TimeStringFormat { unTimeStringFormat :: UTCTime }
    deriving (Eq, Show, Generic)

instance FromHttpApiData TimeStringFormat where
    --parseQueryParam :: Text -> Either Text a
    parseQueryParam queryParam =
        let timeFormat = "%d.%m.%Y"

            --parsedTime :: UTCTime <- parseTimeM False defaultTimeLocale "%d.%m.%Y %T" "04.03.2010 16:05:21"
            parsedTime = parseTimeM False defaultTimeLocale timeFormat $ toS queryParam
        in  TimeStringFormat <$> parsedTime

instance ToParamSchema TimeStringFormat

-- |The data for returning the health check for SMASH.
data HealthStatus = HealthStatus
    { hsStatus  :: !Text
    , hsVersion :: !Text
    } deriving (Eq, Show, Generic)

instance ToJSON HealthStatus where
    toJSON (HealthStatus hsStatus' hsVersion') =
        object
            [ "status"      .= hsStatus'
            , "version"     .= hsVersion'
            ]

instance FromJSON HealthStatus where
    parseJSON = withObject "healthStatus" $ \o -> do
        status          <- o .: "status"
        version         <- o .: "version"

        return $ HealthStatus
            { hsStatus  = status
            , hsVersion = version
            }

instance ToSchema HealthStatus

-- We need a "conversion" layer between custom DB types and the rest of the
-- codebase se we can have a clean separation and replace them at any point.
-- The natural place to have this conversion is in the types.
-- The choice is to use the typeclass here since the operation is general and
-- will be used multiple times (more than 3!).
class DBConversion dbType regularType where
    convertFromDB   :: dbType -> regularType
    convertToDB     :: regularType -> dbType

--instance DBConversion Types.PoolId PoolId where
--    convertFromDB (Types.PoolId poolId) = PoolId poolId
--    convertFromDB (PoolId poolId) = Types.PoolId poolId

