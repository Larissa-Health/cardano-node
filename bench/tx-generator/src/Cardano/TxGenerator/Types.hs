{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# OPTIONS_GHC -fno-warn-partial-fields #-}

{-|
Module      : Cardano.TxGenerator.Types
Description : Types internal to the transaction generator.
-}
module  Cardano.TxGenerator.Types
        (module Cardano.TxGenerator.Types)
        where

import           Cardano.Api

import qualified Cardano.Ledger.Coin as L
import qualified Cardano.Ledger.Shelley.API as Ledger (ShelleyGenesis)
import           Cardano.TxGenerator.Fund (Fund)
import           Cardano.TxGenerator.ProtocolParameters (ProtocolParameters)

import           GHC.Generics (Generic)
import           GHC.Natural
import           Prettyprinter

-- convenience alias for use trhougout the API
type ShelleyGenesis       = Ledger.ShelleyGenesis

-- some type aliases to keep compatibility with code in Cardano.Benchmarking
type NumberOfInputsPerTx  = Int
type NumberOfOutputsPerTx = Int
type NumberOfTxs          = Int
type TxAdditionalSize     = Int
type TPSRate              = Double


type TxGenerator era = [Fund] -> [TxOut CtxTx era] -> Either TxGenError (Tx era, TxId)

type FundSource m       = m (Either TxGenError [Fund])
type FundToStore m      = Fund -> m ()
type FundToStoreList m  = [Fund] -> m ()

data PayWithChange
  = PayExact [L.Coin]
  | PayWithChange L.Coin [L.Coin]


data TxGenTxParams = TxGenTxParams
  { txParamFee        :: !L.Coin                -- ^ Transaction fee, in Lovelace
  , txParamAddTxSize  :: !Int                   -- ^ Extra transaction payload, in bytes -- Note [Tx additional size]
  , txParamTTL        :: !SlotNo                -- ^ Time-to-live
  }
  deriving (Show, Eq)

-- defaults taken from: cardano-node/nix/nixos/tx-generator-service.nix
defaultTxGenTxParams :: TxGenTxParams
defaultTxGenTxParams = TxGenTxParams
  { txParamFee        = 10_000_000
  , txParamAddTxSize  = 100
  , txParamTTL        = 1_000_000
  }


data TxEnvironment era = TxEnvironment
  { txEnvNetworkId        :: !NetworkId
  -- , txEnvGenesis          :: !ShelleyGenesis
  -- , txEnvProtocolInfo     :: !SomeConsensusProtocol
  , txEnvProtocolParams   :: !ProtocolParameters
  , txEnvFee              :: TxFee era
  , txEnvMetadata         :: TxMetadataInEra era
  }


data TxGenConfig = TxGenConfig
  { confMinUtxoValue  :: !L.Coin                -- ^ Minimum value required per UTxO entry
  , confTxsPerSecond  :: !Double                -- ^ Strength of generated workload, in transactions per second
  , confInitCooldown  :: !Double                -- ^ Delay between init and main submissions in seconds
  , confTxsInputs     :: !NumberOfInputsPerTx   -- ^ Inputs per transaction
  , confTxsOutputs    :: !NumberOfOutputsPerTx  -- ^ Outputs per transaction
  }
  deriving (Show, Eq)


data TxGenPlutusType
  = LimitSaturationLoop                         -- ^ Generate Txs for a Plutus loop script, choosing settings to max out per Tx budget
  | LimitTxPerBlock_8                           -- ^ Generate Txs for a Plutus loop script, choosing settings to best fit 8 Txs into block budget
  | LimitTxPerBlock_4                           -- ^ Generate Txs for a Plutus loop script, choosing settings to best fit 4 Txs into block budget
  | BenchCustomCall                             -- ^ Built-in script for benchmarking various complexity of data passed via Plutus API
  | CustomScript
  deriving (Show, Eq, Enum, Generic, FromJSON, ToJSON)

data TxGenPlutusParams
  = PlutusOn                                    -- ^ Generate Plutus Txs for given script
      { plutusType        :: !TxGenPlutusType
      , plutusScript      :: !(Either String FilePath) -- ^ name or path of the Plutus script
      , plutusDatum       :: !(Maybe FilePath)  -- ^ Datum passed to the Plutus script (JSON file in ScriptData schema)
      , plutusRedeemer    :: !(Maybe FilePath)  -- ^ Redeemer passed to the Plutus script (JSON file in ScriptData schema)
      , plutusExecMemory  :: !(Maybe Natural)   -- ^ Max. memory for ExecutionUnits (overriding corresponding protocol parameter)
      , plutusExecSteps   :: !(Maybe Natural)   -- ^ Max. steps for ExecutionUnits (overriding corresponding protocol parameter)
      }
  | PlutusOff                                   -- ^ Do not generate Plutus Txs
  deriving (Show, Eq)

-- | Documents how the `plutusScript` parameter above was eventually resolved
data TxGenPlutusResolvedTo
  = ResolvedToLibrary     String      -- ^ source is the library from the plutus-scripts-bench package
  | ResolvedToFallback    FilePath    -- ^ source it the tx-generator's scripts-fallback data directory
  | ResolvedToFileName    FilePath    -- ^ source is a .plutus file
  deriving Eq

instance Show TxGenPlutusResolvedTo where
  show = \case
    ResolvedToLibrary n ->   "builtin: " ++ n
    ResolvedToFallback f  -> "fallback: " ++ f
    ResolvedToFileName f  -> "file: " ++ f

isPlutusMode :: TxGenPlutusParams -> Bool
isPlutusMode
  = (/= PlutusOff)

hasLoopCalibration :: TxGenPlutusType -> Bool
hasLoopCalibration t
  = t == LimitTxPerBlock_8 || t == LimitTxPerBlock_4 || t == LimitSaturationLoop

hasStaticBudget :: TxGenPlutusParams -> Maybe ExecutionUnits
hasStaticBudget
  = \case
    PlutusOn{plutusExecMemory = m, plutusExecSteps = s} -> ExecutionUnits <$> s <*> m
    _ -> Nothing

data PlutusAutoBudget
  = PlutusAutoBudget                                 -- ^ Specifies a budget and parameters for a PlutusAuto loop script
    { autoBudgetUnits           :: !ExecutionUnits   -- ^ execution units available per Tx input / script run
    , autoBudgetDatum           :: !ScriptData       -- ^ datum for the auto script
    , autoBudgetRedeemer        :: !ScriptRedeemer   -- ^ valid redeemer for the auto script
    , autoBudgetUpperBoundHint  :: !(Maybe Int)      -- ^ hints at a loop count upper bount; speeds up calibration for scripts with low loop counts, but does not influence outcome
    }
    deriving (Show, Eq)

data TxGenError where
  ApiError        :: Cardano.Api.Error e => !e -> TxGenError
  ProtocolError   :: Cardano.Api.Error e => !e -> TxGenError
  PlutusError     :: Show e => !e -> TxGenError
  TxGenError      :: !String -> TxGenError

instance Show TxGenError where
  show (ApiError e) = docToString $ "ApiError " <> parens (prettyError e)
  show (ProtocolError e) = docToString $ "ProtocolError " <> parens (prettyError e)
  show (PlutusError e) = docToString $ "ProtocolError " <> parens (pshow e)
  show (TxGenError e) = docToString $ "ApiError " <> parens (pshow e)

instance Semigroup TxGenError where
  TxGenError a <> TxGenError b  = TxGenError (a <> b)
  TxGenError a <> b             = TxGenError (a <> docToString (pshow b))
  a            <> TxGenError b  = TxGenError (docToString (pshow a) <> b)
  a            <> b             = TxGenError $ docToString (pshow a <> pshow b)

instance Error TxGenError where
  prettyError = \case
    ApiError e        -> prettyError e
    ProtocolError e   -> prettyError e
    _                 -> ""

{-
Note [Tx additional size]
~~~~~~~~~~~~~~~~~~~~~~~~~
This parameter specifies the additional size (in bytes) of a transaction.
Since one transaction is ([input] + [output] + attributes), its size
is defined by its inputs and outputs. We want to have an ability to
increase a transaction's size without increasing the number of inputs or
outputs. Such a big transaction will give us more real-world results
of benchmarking.
Technically, this parameter specifies the size of the attribute we'll
add to the transaction (by default attributes are empty, so if this
parameter is skipped, attributes will remain empty).
-}
