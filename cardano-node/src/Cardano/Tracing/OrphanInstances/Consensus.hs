{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wno-deprecations #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Tracing.OrphanInstances.Consensus () where

import           Cardano.Node.Tracing.Tracers.ConsensusStartupException
                   (ConsensusStartupException (..))
import           Cardano.Prelude (Typeable, maximumDef)
import           Cardano.Slotting.Slot (fromWithOrigin)
import           Cardano.Tracing.OrphanInstances.Common
import           Cardano.Tracing.OrphanInstances.Network ()
import           Cardano.Tracing.Render (renderChainHash, renderChunkNo, renderHeaderHash,
                   renderHeaderHashForVerbosity, renderPointAsPhrase, renderPointForVerbosity,
                   renderRealPoint, renderRealPointAsPhrase, renderTipBlockNo, renderTipHash,
                   renderWithOrigin)
import           Ouroboros.Consensus.Block (BlockProtocol, BlockSupportsProtocol, CannotForge,
                   ConvertRawHash (..), ForgeStateUpdateError, GenesisWindow (..), GetHeader (..),
                   Header, RealPoint, blockNo, blockPoint, blockPrevHash, getHeader, pointHash,
                   realPointHash, realPointSlot, withOriginToMaybe)
import           Ouroboros.Consensus.Block.SupportsSanityCheck
import           Ouroboros.Consensus.Genesis.Governor (DensityBounds (..), GDDDebugInfo (..),
                   TraceGDDEvent (..))
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Ledger.Inspect (InspectLedger, LedgerEvent (..), LedgerUpdate,
                   LedgerWarning)
import           Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr, ByteSize32 (..), GenTx,
                   GenTxId, HasTxId, LedgerSupportsMempool, TxId, txForgetValidated, txId)
import           Ouroboros.Consensus.Ledger.SupportsProtocol (LedgerSupportsProtocol)
import           Ouroboros.Consensus.Mempool (MempoolSize (..), TraceEventMempool (..))
import           Ouroboros.Consensus.MiniProtocol.BlockFetch.Server
                   (TraceBlockFetchServerEvent (..))
import           Ouroboros.Consensus.MiniProtocol.ChainSync.Client (TraceChainSyncClientEvent (..))
import qualified Ouroboros.Consensus.MiniProtocol.ChainSync.Client.Jumping as ChainSync.Client
import qualified Ouroboros.Consensus.MiniProtocol.ChainSync.Client.State as ChainSync.Client
import           Ouroboros.Consensus.MiniProtocol.ChainSync.Server (BlockingType (..),
                   TraceChainSyncServerEvent (..))
import           Ouroboros.Consensus.MiniProtocol.LocalTxSubmission.Server
                   (TraceLocalTxSubmissionServerEvent (..))
import           Ouroboros.Consensus.Node.GSM
import           Ouroboros.Consensus.Node.Run (RunNode, estimateBlockSize)
import           Ouroboros.Consensus.Node.Tracers (TraceForgeEvent (..))
import qualified Ouroboros.Consensus.Node.Tracers as Consensus
import           Ouroboros.Consensus.Protocol.Abstract
import qualified Ouroboros.Consensus.Protocol.BFT as BFT
import qualified Ouroboros.Consensus.Protocol.PBFT as PBFT
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import qualified Ouroboros.Consensus.Storage.ImmutableDB.API as ImmDB
import           Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (ChunkNo (..),
                   chunkNoToInt)
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Types as ImmDB
import           Ouroboros.Consensus.Storage.LedgerDB (PushGoal (..), PushStart (..), Pushing (..))
import qualified Ouroboros.Consensus.Storage.LedgerDB as LedgerDB
import qualified Ouroboros.Consensus.Storage.LedgerDB.Snapshots as LedgerDB
import qualified Ouroboros.Consensus.Storage.VolatileDB.Impl as VolDb
import           Ouroboros.Consensus.Util.Condense
import           Ouroboros.Consensus.Util.Enclose
import           Ouroboros.Consensus.Util.Orphans ()
import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block (BlockNo (..), ChainUpdate (..), MaxSlotNo (..),
                   SlotNo (..), StandardHash, Tip (..), blockHash, pointSlot, tipFromHeader)
import           Ouroboros.Network.BlockFetch.ClientState (TraceLabelPeer (..))
import           Ouroboros.Network.Point (withOrigin)
import           Ouroboros.Network.SizeInBytes (SizeInBytes (..))

import           Control.Monad (guard)
import           Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import           Data.Foldable (Foldable (..))
import           Data.Function (on)
import           Data.Proxy
import           Data.Text (Text, pack)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Word (Word32)
import           GHC.Generics (Generic)
import           Network.TypedProtocol.Core
import           Numeric (showFFloat)


{- HLINT ignore "Use const" -}
{- HLINT ignore "Use record patterns" -}

instance ToObject ConsensusStartupException where
  toObject _ (ConsensusStartupException err) =
    mconcat
      [ "kind" .= String "ConsensusStartupException"
      , "error" .= String (pack . show $ err)
      ]

instance HasPrivacyAnnotation ConsensusStartupException where
instance HasSeverityAnnotation ConsensusStartupException where
  getSeverityAnnotation _ = Critical
instance Transformable Text IO ConsensusStartupException where
  trTransformer = trStructured
instance HasTextFormatter ConsensusStartupException where

instance HasPrivacyAnnotation SanityCheckIssue
instance HasSeverityAnnotation SanityCheckIssue where
  getSeverityAnnotation _ = Error
instance Transformable Text IO SanityCheckIssue where
  trTransformer = trStructured

instance ToObject SanityCheckIssue where
  toObject _verb issue =
    mconcat
      [ "kind" .= String "SanityCheckIssue"
      , "issue" .= toJSON issue
      ]
instance ToJSON SanityCheckIssue where
  toJSON = Aeson.String . pack . show

instance ConvertRawHash blk => ConvertRawHash (Header blk) where
  toShortRawHash _ = toShortRawHash (Proxy @blk)
  fromShortRawHash _ = fromShortRawHash (Proxy @blk)
  hashSize :: proxy (Header blk) -> Word32
  hashSize _ = hashSize (Proxy @blk)

instance ConvertRawHash blk => ConvertRawHash (HeaderWithTime blk) where
  toShortRawHash _ = toShortRawHash (Proxy @blk)
  fromShortRawHash _ = fromShortRawHash (Proxy @blk)
  hashSize :: proxy (HeaderWithTime blk) -> Word32
  hashSize _ = hashSize (Proxy @blk)

--
-- * instances of @HasPrivacyAnnotation@ and @HasSeverityAnnotation@
--
-- NOTE: this list is sorted by the unqualified name of the outermost type.

instance HasPrivacyAnnotation (ChainDB.TraceEvent blk)
instance HasSeverityAnnotation (ChainDB.TraceEvent blk) where
  getSeverityAnnotation (ChainDB.TraceAddBlockEvent ev) = case ev of
    ChainDB.IgnoreBlockOlderThanK {} -> Info
    ChainDB.IgnoreBlockAlreadyInVolatileDB {} -> Info
    ChainDB.IgnoreInvalidBlock {} -> Info
    ChainDB.AddedBlockToQueue {} -> Debug
    ChainDB.PoppedBlockFromQueue {} -> Debug
    ChainDB.AddedBlockToVolatileDB {} -> Debug
    ChainDB.TryAddToCurrentChain {} -> Debug
    ChainDB.TrySwitchToAFork {} -> Info
    ChainDB.StoreButDontChange {} -> Debug
    ChainDB.ChangingSelection {} -> Debug
    ChainDB.AddedToCurrentChain events _ _ _ ->
      maximumDef Notice (map getSeverityAnnotation events)
    ChainDB.SwitchedToAFork events _ _ _ ->
      maximumDef Notice (map getSeverityAnnotation events)
    ChainDB.AddBlockValidation ev' -> case ev' of
      ChainDB.InvalidBlock {} -> Error
      ChainDB.ValidCandidate {} -> Info
      ChainDB.UpdateLedgerDbTraceEvent {} -> Debug
    ChainDB.PipeliningEvent {} -> Debug
    ChainDB.AddedReprocessLoEBlocksToQueue -> Debug
    ChainDB.PoppedReprocessLoEBlocksFromQueue -> Debug
    ChainDB.ChainSelectionLoEDebug _ _ -> Debug


  getSeverityAnnotation (ChainDB.TraceLedgerDBEvent ev) = case ev of
    LedgerDB.LedgerDBSnapshotEvent ev' -> case ev' of
      LedgerDB.TookSnapshot {} -> Info
      LedgerDB.DeletedSnapshot {} -> Debug
      LedgerDB.InvalidSnapshot _ invalidWhy -> case invalidWhy of
        LedgerDB.InitFailureRead (LedgerDB.ReadMetadataError _ LedgerDB.MetadataBackendMismatch) -> Warning
        LedgerDB.InitFailureRead (LedgerDB.ReadMetadataError _ LedgerDB.MetadataFileDoesNotExist) -> Warning
        _ -> Error
    LedgerDB.LedgerReplayEvent {} -> Info
    LedgerDB.LedgerDBForkerEvent {} -> Debug
    LedgerDB.LedgerDBFlavorImplEvent {} -> Debug

  getSeverityAnnotation (ChainDB.TraceCopyToImmutableDBEvent ev) = case ev of
    ChainDB.CopiedBlockToImmutableDB {} -> Debug
    ChainDB.NoBlocksToCopyToImmutableDB -> Debug

  getSeverityAnnotation (ChainDB.TraceGCEvent ev) = case ev of
    ChainDB.PerformedGC {} -> Debug
    ChainDB.ScheduledGC {} -> Debug

  getSeverityAnnotation (ChainDB.TraceOpenEvent ev) = case ev of
    ChainDB.OpenedDB {} -> Info
    ChainDB.ClosedDB {} -> Info
    ChainDB.OpenedImmutableDB {} -> Info
    ChainDB.OpenedVolatileDB {} -> Info
    ChainDB.OpenedLgrDB -> Info
    ChainDB.StartedOpeningDB -> Info
    ChainDB.StartedOpeningImmutableDB -> Info
    ChainDB.StartedOpeningVolatileDB -> Info
    ChainDB.StartedOpeningLgrDB -> Info

  getSeverityAnnotation (ChainDB.TraceFollowerEvent ev) = case ev of
    ChainDB.NewFollower {} -> Debug
    ChainDB.FollowerNoLongerInMem {} -> Debug
    ChainDB.FollowerSwitchToMem {} -> Debug
    ChainDB.FollowerNewImmIterator {} -> Debug
  getSeverityAnnotation (ChainDB.TraceInitChainSelEvent ev) = case ev of
    ChainDB.StartedInitChainSelection{} -> Info
    ChainDB.InitialChainSelected{} -> Info
    ChainDB.InitChainSelValidation ev' -> case ev' of
      ChainDB.InvalidBlock{} -> Debug
      ChainDB.ValidCandidate {} -> Info
      ChainDB.UpdateLedgerDbTraceEvent {} -> Info

  getSeverityAnnotation (ChainDB.TraceIteratorEvent ev) = case ev of
    ChainDB.StreamFromVolatileDB {} -> Debug
    _ -> Debug
  getSeverityAnnotation (ChainDB.TraceImmutableDBEvent ev) = case ev of
    ImmDB.NoValidLastLocation {} -> Info
    ImmDB.ValidatedLastLocation {} -> Info
    ImmDB.ChunkValidationEvent ev' -> case ev' of
      ImmDB.StartedValidatingChunk{} -> Info
      ImmDB.ValidatedChunk{}         -> Info
      ImmDB.MissingChunkFile{}       -> Warning
      ImmDB.InvalidChunkFile {}      -> Warning
      ImmDB.MissingPrimaryIndex{}    -> Warning
      ImmDB.MissingSecondaryIndex{}  -> Warning
      ImmDB.InvalidPrimaryIndex{}    -> Warning
      ImmDB.InvalidSecondaryIndex{}  -> Warning
      ImmDB.RewritePrimaryIndex{}    -> Warning
      ImmDB.RewriteSecondaryIndex{}  -> Warning
    ImmDB.ChunkFileDoesntFit{} -> Warning
    ImmDB.Migrating{}          -> Debug
    ImmDB.DeletingAfter{}      -> Debug
    ImmDB.DBAlreadyClosed{}    -> Error
    ImmDB.DBClosed{}           -> Info
    ImmDB.TraceCacheEvent{}    -> Debug
  getSeverityAnnotation (ChainDB.TraceVolatileDBEvent ev) = case ev of
    VolDb.DBAlreadyClosed{}     -> Error
    VolDb.BlockAlreadyHere{}    -> Debug
    VolDb.Truncate{}            -> Error
    VolDb.InvalidFileNames{}    -> Warning
    VolDb.DBClosed{}            -> Info
  getSeverityAnnotation ChainDB.TraceLastShutdownUnclean = Warning

  getSeverityAnnotation ChainDB.TraceChainSelStarvationEvent{} = Debug

instance HasSeverityAnnotation (LedgerEvent blk) where
  getSeverityAnnotation (LedgerUpdate _)  = Notice
  getSeverityAnnotation (LedgerWarning _) = Critical

instance HasPrivacyAnnotation (TraceBlockFetchServerEvent blk)
instance HasSeverityAnnotation (TraceBlockFetchServerEvent blk) where
  getSeverityAnnotation _ = Info

instance (ToObject peer, ToObject (TraceChainSyncClientEvent blk))
    => Transformable Text IO (TraceLabelPeer peer (TraceChainSyncClientEvent blk)) where
  trTransformer = trStructured
instance (BlockSupportsProtocol blk, Show peer, Show (Header blk))
    => HasTextFormatter (TraceLabelPeer peer (TraceChainSyncClientEvent blk)) where
  formatText a _ = pack $ show a

instance HasPrivacyAnnotation (TraceChainSyncClientEvent blk)
instance HasSeverityAnnotation (TraceChainSyncClientEvent blk) where
  getSeverityAnnotation (TraceDownloadedHeader _) = Info
  getSeverityAnnotation (TraceFoundIntersection _ _ _) = Info
  getSeverityAnnotation (TraceRolledBack _) = Notice
  getSeverityAnnotation (TraceException _) = Warning
  getSeverityAnnotation (TraceTermination _) = Notice
  getSeverityAnnotation (TraceValidatedHeader _) = Debug
  getSeverityAnnotation (TraceWaitingBeyondForecastHorizon _) = Debug
  getSeverityAnnotation (TraceAccessingForecastHorizon _) = Debug
  getSeverityAnnotation (TraceGaveLoPToken _ _ _) = Debug
  getSeverityAnnotation (TraceOfferJump _) = Debug
  getSeverityAnnotation (TraceJumpResult _) = Debug
  getSeverityAnnotation TraceJumpingWaitingForNextInstruction = Debug
  getSeverityAnnotation (TraceJumpingInstructionIs _) = Debug
  getSeverityAnnotation (TraceDrainingThePipe _) = Debug


instance HasPrivacyAnnotation (TraceChainSyncServerEvent blk)
instance HasSeverityAnnotation (TraceChainSyncServerEvent blk) where
  getSeverityAnnotation _ = Info


instance HasPrivacyAnnotation (TraceEventMempool blk)
instance HasSeverityAnnotation (TraceEventMempool blk) where
  getSeverityAnnotation TraceMempoolAddedTx{} = Info
  getSeverityAnnotation TraceMempoolRejectedTx{} = Info
  getSeverityAnnotation TraceMempoolRemoveTxs{} = Debug
  getSeverityAnnotation TraceMempoolManuallyRemovedTxs{} = Warning
  getSeverityAnnotation TraceMempoolSyncNotNeeded{} = Debug
  getSeverityAnnotation TraceMempoolSynced{} = Debug
  getSeverityAnnotation TraceMempoolAttemptingAdd{} = Debug
  getSeverityAnnotation TraceMempoolLedgerFound{} = Debug
  getSeverityAnnotation TraceMempoolLedgerNotFound{} = Debug

instance HasPrivacyAnnotation ()
instance HasSeverityAnnotation () where
  getSeverityAnnotation () = Info

instance HasPrivacyAnnotation (TraceForgeEvent blk)
instance HasSeverityAnnotation (TraceForgeEvent blk) where
  getSeverityAnnotation TraceStartLeadershipCheck {}   = Info
  getSeverityAnnotation TraceSlotIsImmutable {}        = Error
  getSeverityAnnotation TraceBlockFromFuture {}        = Error
  getSeverityAnnotation TraceBlockContext {}           = Debug
  getSeverityAnnotation TraceNoLedgerState {}          = Error
  getSeverityAnnotation TraceLedgerState {}            = Debug
  getSeverityAnnotation TraceNoLedgerView {}           = Error
  getSeverityAnnotation TraceLedgerView {}             = Debug
  getSeverityAnnotation TraceForgeStateUpdateError {}  = Error
  getSeverityAnnotation TraceNodeCannotForge {}        = Error
  getSeverityAnnotation TraceNodeNotLeader {}          = Info
  getSeverityAnnotation TraceNodeIsLeader {}           = Info
  getSeverityAnnotation TraceForgeTickedLedgerState {} = Debug
  getSeverityAnnotation TraceForgingMempoolSnapshot {} = Debug
  getSeverityAnnotation TraceForgedBlock {}            = Info
  getSeverityAnnotation TraceDidntAdoptBlock {}        = Error
  getSeverityAnnotation TraceForgedInvalidBlock {}     = Error
  getSeverityAnnotation TraceAdoptedBlock {}           = Info
  getSeverityAnnotation TraceAdoptionThreadDied {}     = Error


instance HasPrivacyAnnotation (TraceLocalTxSubmissionServerEvent blk)
instance HasSeverityAnnotation (TraceLocalTxSubmissionServerEvent blk) where
  getSeverityAnnotation _ = Info


--
-- | instances of @Transformable@
--
-- NOTE: this list is sorted by the unqualified name of the outermost type.

instance ( HasPrivacyAnnotation (ChainDB.TraceAddBlockEvent blk)
         , HasSeverityAnnotation (ChainDB.TraceAddBlockEvent blk)
         , LedgerSupportsProtocol blk
         , ToObject (ChainDB.TraceAddBlockEvent blk))
      => Transformable Text IO (ChainDB.TraceAddBlockEvent blk) where
  trTransformer = trStructuredText


instance (LedgerSupportsProtocol blk)
      => HasTextFormatter (ChainDB.TraceAddBlockEvent blk) where
  formatText _ = pack . show . toList


instance (ToObject peer, ConvertRawHash blk)
      => Transformable Text IO (TraceLabelPeer peer (TraceBlockFetchServerEvent blk)) where
  trTransformer = trStructuredText


instance HasTextFormatter (TraceLabelPeer peer (TraceBlockFetchServerEvent blk)) where
  formatText _ = pack . show . toList


instance (ConvertRawHash blk, LedgerSupportsProtocol blk)
      => Transformable Text IO (TraceChainSyncClientEvent blk) where
  trTransformer = trStructured


instance ConvertRawHash blk
      => Transformable Text IO (TraceChainSyncServerEvent blk) where
  trTransformer = trStructured

instance (ToObject peer, ToObject (TraceChainSyncServerEvent blk))
    => Transformable Text IO (TraceLabelPeer peer (TraceChainSyncServerEvent blk)) where
  trTransformer = trStructured
instance (StandardHash blk, Show peer)
    => HasTextFormatter (TraceLabelPeer peer (TraceChainSyncServerEvent blk)) where
  formatText a _ = pack $ show a


instance ( ToObject (ApplyTxErr blk), ToObject (GenTx blk),
           ToJSON (GenTxId blk), LedgerSupportsMempool blk,
           ConvertRawHash blk)
      => Transformable Text IO (TraceEventMempool blk) where
  trTransformer = trStructured

instance Condense t => Condense (Enclosing' t) where
  condense RisingEdge = "RisingEdge"
  condense (FallingEdgeWith a) = "FallingEdge: " <> condense a

deriving instance Generic (Enclosing' t)
instance ToJSON t => ToJSON (Enclosing' t)

condenseT :: Condense a => a -> Text
condenseT = pack . condense

showT :: Show a => a -> Text
showT = pack . show


instance ( tx ~ GenTx blk
         , HasTxId tx
         , RunNode blk
         , ToObject (LedgerError blk)
         , ToObject (OtherHeaderEnvelopeError blk)
         , ToObject (ValidationErr (BlockProtocol blk))
         , ToObject (CannotForge blk)
         , ToObject (ForgeStateUpdateError blk)
         , LedgerSupportsMempool blk)
      => Transformable Text IO (TraceForgeEvent blk) where
  trTransformer = trStructuredText

instance ( tx ~ GenTx blk
         , ConvertRawHash blk
         , HasTxId tx
         , LedgerSupportsMempool blk
         , LedgerSupportsProtocol blk
         , LedgerSupportsMempool blk
         , Show (TxId tx)
         , Show (ForgeStateUpdateError blk)
         , Show (CannotForge blk)
         , LedgerSupportsMempool blk)
      => HasTextFormatter (TraceForgeEvent blk) where
  formatText = \case
    TraceStartLeadershipCheck slotNo -> const $
      "Checking for leadership in slot " <> showT (unSlotNo slotNo)
    TraceSlotIsImmutable slotNo immutableTipPoint immutableTipBlkNo -> const $
      "Couldn't forge block because current slot is immutable: "
        <> "immutable tip: " <> renderPointAsPhrase immutableTipPoint
        <> ", immutable tip block no: " <> showT (unBlockNo immutableTipBlkNo)
        <> ", current slot: " <> showT (unSlotNo slotNo)
    TraceBlockFromFuture currentSlot tipSlot -> const $
      "Couldn't forge block because current tip is in the future: "
        <> "current tip slot: " <> showT (unSlotNo tipSlot)
        <> ", current slot: " <> showT (unSlotNo currentSlot)
    TraceBlockContext currentSlot tipBlockNo tipPoint -> const $
      "New block will fit onto: "
        <> "tip: " <> renderPointAsPhrase tipPoint
        <> ", tip block no: " <> showT (unBlockNo tipBlockNo)
        <> ", current slot: " <> showT (unSlotNo currentSlot)
    TraceNoLedgerState slotNo pt -> const $
      "Could not obtain ledger state for point "
        <> renderPointAsPhrase pt
        <> ", current slot: "
        <> showT (unSlotNo slotNo)
    TraceLedgerState slotNo pt -> const $
      "Obtained a ledger state for point "
        <> renderPointAsPhrase pt
        <> ", current slot: "
        <> showT (unSlotNo slotNo)
    TraceNoLedgerView slotNo _ -> const $
      "Could not obtain ledger view for slot " <> showT (unSlotNo slotNo)
    TraceLedgerView slotNo -> const $
      "Obtained a ledger view for slot " <> showT (unSlotNo slotNo)
    TraceForgeStateUpdateError slotNo reason -> const $
      "Updating the forge state in slot "
        <> showT (unSlotNo slotNo)
        <> " failed because: "
        <> showT reason
    TraceNodeCannotForge slotNo reason -> const $
      "We are the leader in slot "
        <> showT (unSlotNo slotNo)
        <> ", but we cannot forge because: "
        <> showT reason
    TraceNodeNotLeader slotNo -> const $
      "Not leading slot " <> showT (unSlotNo slotNo)
    TraceNodeIsLeader slotNo -> const $
      "Leading slot " <> showT (unSlotNo slotNo)
    TraceForgeTickedLedgerState slotNo prevPt -> const $
      "While forging in slot "
        <> showT (unSlotNo slotNo)
        <> " we ticked the ledger state ahead from "
        <> renderPointAsPhrase prevPt
    TraceForgingMempoolSnapshot slotNo prevPt mpHash mpSlot -> const $
      "While forging in slot "
        <> showT (unSlotNo slotNo)
        <> " we acquired a mempool snapshot valid against "
        <> renderPointAsPhrase prevPt
        <> " from a mempool that was prepared for "
        <> renderChainHash (Text.decodeLatin1 . toRawHash (Proxy @blk)) mpHash
        <> " ticked to slot "
        <> showT (unSlotNo mpSlot)
    TraceForgedBlock slotNo _ _ _ -> const $
      "Forged block in slot " <> showT (unSlotNo slotNo)
    TraceDidntAdoptBlock slotNo _ -> const $
      "Didn't adopt forged block in slot " <> showT (unSlotNo slotNo)
    TraceForgedInvalidBlock slotNo _ reason -> const $
      "Forged invalid block in slot "
        <> showT (unSlotNo slotNo)
        <> ", reason: " <> showT reason
    TraceAdoptedBlock slotNo blk txs -> const $
      "Adopted block forged in slot "
        <> showT (unSlotNo slotNo)
        <> ": " <> renderHeaderHash (Proxy @blk) (blockHash blk)
        <> ", TxIds: " <> showT (map (txId . txForgetValidated) txs)
    TraceAdoptionThreadDied slotNo blk -> const $
      "Adoption Thread died in slot "
        <> showT (unSlotNo slotNo)
        <> ": " <> renderHeaderHash (Proxy @blk) (blockHash blk)


instance Transformable Text IO (TraceLocalTxSubmissionServerEvent blk) where
  trTransformer = trStructured

instance HasPrivacyAnnotation a => HasPrivacyAnnotation (Consensus.TraceLabelCreds a)
instance HasSeverityAnnotation a => HasSeverityAnnotation (Consensus.TraceLabelCreds a) where
  getSeverityAnnotation (Consensus.TraceLabelCreds _ a) = getSeverityAnnotation a

instance ToObject a => ToObject (Consensus.TraceLabelCreds a) where
  toObject verb (Consensus.TraceLabelCreds creds val) =
    mconcat [ "credentials" .= toJSON creds
            , "val"         .= toObject verb val
            ]

instance (HasPrivacyAnnotation a, HasSeverityAnnotation a, ToObject a)
      => Transformable Text IO (Consensus.TraceLabelCreds a) where
  trTransformer = trStructured

instance ( ConvertRawHash blk
         , LedgerSupportsProtocol blk
         , InspectLedger blk
         , ToObject (Header blk)
         , ToObject (LedgerEvent blk)
         , ToObject (SelectView (BlockProtocol blk)))
      => Transformable Text IO (ChainDB.TraceEvent blk) where
  trTransformer = trStructuredText

instance ( ConvertRawHash blk
         , LedgerSupportsProtocol blk
         , InspectLedger blk)
      => HasTextFormatter (ChainDB.TraceEvent blk) where
    formatText tev _obj = case tev of
      ChainDB.TraceLastShutdownUnclean -> "ChainDB is not clean. Validating all immutable chunks"
      ChainDB.TraceAddBlockEvent ev -> case ev of
        ChainDB.IgnoreBlockOlderThanK pt ->
          "Ignoring block older than K: " <> renderRealPointAsPhrase pt
        ChainDB.IgnoreBlockAlreadyInVolatileDB pt ->
          "Ignoring block already in DB: " <> renderRealPointAsPhrase pt
        ChainDB.IgnoreInvalidBlock pt _reason ->
          "Ignoring previously seen invalid block: " <> renderRealPointAsPhrase pt
        ChainDB.AddedBlockToQueue pt edgeSz ->
          case edgeSz of
            RisingEdge ->
              "About to add block to queue: " <> renderRealPointAsPhrase pt
            FallingEdgeWith sz ->
              "Block added to queue: " <> renderRealPointAsPhrase pt <> " queue size " <> condenseT sz
        ChainDB.AddedReprocessLoEBlocksToQueue ->
          "Added request to queue to reprocess blocks postponed by LoE."
        ChainDB.PoppedReprocessLoEBlocksFromQueue ->
          "Poppped request from queue to reprocess blocks postponed by LoE."
        ChainDB.ChainSelectionLoEDebug {} ->
          "ChainDB LoE debug event"

        ChainDB.PoppedBlockFromQueue edgePt ->
          case edgePt of
            RisingEdge ->
              "Popping block from queue"
            FallingEdgeWith pt ->
              "Popped block from queue: " <> renderRealPointAsPhrase pt
        ChainDB.StoreButDontChange pt ->
          "Ignoring block: " <> renderRealPointAsPhrase pt
        ChainDB.TryAddToCurrentChain pt ->
          "Block fits onto the current chain: " <> renderRealPointAsPhrase pt
        ChainDB.TrySwitchToAFork pt _ ->
          "Block fits onto some fork: " <> renderRealPointAsPhrase pt
        ChainDB.ChangingSelection pt ->
          "Changing selection to: " <> renderPointAsPhrase pt
        ChainDB.AddedToCurrentChain es _ _ c ->
          "Chain extended, new tip: " <> renderPointAsPhrase (AF.headPoint c) <>
          Text.concat [ "\nEvent: " <> showT e | e <- es ]
        ChainDB.SwitchedToAFork es _ _ c ->
          "Switched to a fork, new tip: " <> renderPointAsPhrase (AF.headPoint c) <>
          Text.concat [ "\nEvent: " <> showT e | e <- es ]
        ChainDB.AddBlockValidation ev' -> case ev' of
          ChainDB.InvalidBlock err pt ->
            "Invalid block " <> renderRealPointAsPhrase pt <> ": " <> showT err
          ChainDB.ValidCandidate c ->
            "Valid candidate spanning from " <> renderPointAsPhrase (AF.lastPoint c) <> " to " <> renderPointAsPhrase (AF.headPoint c)
          ChainDB.UpdateLedgerDbTraceEvent (LedgerDB.StartedPushingBlockToTheLedgerDb  (PushStart start) (PushGoal goal) (Pushing curr)) ->
            let fromSlot = unSlotNo $ realPointSlot start
                atSlot   = unSlotNo $ realPointSlot curr
                atDiff   = atSlot - fromSlot
                toSlot   = unSlotNo $ realPointSlot goal
                toDiff   = toSlot - fromSlot
            in
              "Pushing ledger state for block " <> renderRealPointAsPhrase curr <> ". Progress: " <>
              showProgressT (fromIntegral atDiff) (fromIntegral toDiff) <> "%"
        ChainDB.AddedBlockToVolatileDB pt _ _ enclosing -> case enclosing of
          RisingEdge  -> "Chain about to add block " <> renderRealPointAsPhrase pt
          FallingEdge -> "Chain added block " <> renderRealPointAsPhrase pt
        ChainDB.PipeliningEvent ev' -> case ev' of
          ChainDB.SetTentativeHeader hdr enclosing -> case enclosing of
            RisingEdge  -> "About to set tentative header to " <> renderPointAsPhrase (blockPoint hdr)
            FallingEdge -> "Set tentative header to " <> renderPointAsPhrase (blockPoint hdr)
          ChainDB.TrapTentativeHeader hdr -> "Discovered trap tentative header " <> renderPointAsPhrase (blockPoint hdr)
          ChainDB.OutdatedTentativeHeader hdr -> "Tentative header is now outdated" <> renderPointAsPhrase (blockPoint hdr)

      ChainDB.TraceLedgerDBEvent ev -> case ev of
        LedgerDB.LedgerDBSnapshotEvent ev' -> case ev' of
          LedgerDB.InvalidSnapshot snap failure ->
            "Invalid snapshot " <> showT snap <> showT failure <> context
            where
              context = case failure of
                LedgerDB.InitFailureRead LedgerDB.ReadSnapshotFailed{} ->
                     " This is most likely an expected change in the serialization format,"
                  <> " which currently requires a chain replay"
                LedgerDB.InitFailureRead LedgerDB.ReadSnapshotDataCorruption ->
                     " The snapshot fails the CRC check. It seems there has been disk corruption"
                LedgerDB.InitFailureRead (LedgerDB.ReadMetadataError _ err) -> case err of
                  LedgerDB.MetadataFileDoesNotExist ->
                     " The snapshot doesn't have the required metadata file."
                  LedgerDB.MetadataInvalid errMsg ->
                     " Snapshot metadata file failed to deserialize: " <> showT errMsg
                  LedgerDB.MetadataBackendMismatch ->
                     " Snapshot was created for a different backend. Convert it with `snapshot-converter`."
                _ -> ""
          LedgerDB.TookSnapshot snap pt RisingEdge ->
            "Taking ledger snapshot " <> showT snap <>
            " at " <> renderRealPointAsPhrase pt
          LedgerDB.TookSnapshot snap pt (FallingEdgeWith t) ->
            "Took ledger snapshot " <> showT snap <>
            " at " <> renderRealPointAsPhrase pt <>
            ", duration: " <> showT t
          LedgerDB.DeletedSnapshot snap ->
            "Deleted old snapshot " <> showT snap
        LedgerDB.LedgerReplayEvent ev' -> case ev' of
          LedgerDB.TraceReplayStartEvent ev'' -> case ev'' of
            LedgerDB.ReplayFromGenesis ->
              "Replaying ledger from genesis"
            LedgerDB.ReplayFromSnapshot _ (LedgerDB.ReplayStart tip') ->
              "Replaying ledger from snapshot at " <>
                renderPointAsPhrase tip'
          LedgerDB.TraceReplayProgressEvent
            (LedgerDB.ReplayedBlock pt _ledgerEvents (LedgerDB.ReplayStart replayFrom) (LedgerDB.ReplayGoal replayTo)) ->
            let fromSlot = withOrigin 0 Prelude.id $ unSlotNo <$> pointSlot replayFrom
                atSlot   = unSlotNo $ realPointSlot pt
                atDiff   = atSlot - fromSlot
                toSlot   = withOrigin 0 Prelude.id $ unSlotNo <$> pointSlot replayTo
                toDiff   = toSlot - fromSlot
            in
               "Replayed block: slot "
            <> showT atSlot
            <> " out of "
            <> showT toSlot
            <> ". Progress: "
            <> showProgressT (fromIntegral atDiff) (fromIntegral toDiff)
            <> "%"
        LedgerDB.LedgerDBForkerEvent ev' -> showT ev'
        LedgerDB.LedgerDBFlavorImplEvent ev' -> showT ev'

      ChainDB.TraceCopyToImmutableDBEvent ev -> case ev of
        ChainDB.CopiedBlockToImmutableDB pt ->
          "Copied block " <> renderPointAsPhrase pt <> " to the ImmutableDB"
        ChainDB.NoBlocksToCopyToImmutableDB ->
          "There are no blocks to copy to the ImmutableDB"
      ChainDB.TraceGCEvent ev -> case ev of
        ChainDB.PerformedGC slot ->
          "Performed a garbage collection for " <> condenseT slot
        ChainDB.ScheduledGC slot _difft ->
          "Scheduled a garbage collection for " <> condenseT slot
      ChainDB.TraceOpenEvent ev -> case ev of
        ChainDB.StartedOpeningDB -> "Started opening Chain DB"
        ChainDB.StartedOpeningImmutableDB -> "Started opening Immutable DB"
        ChainDB.StartedOpeningVolatileDB -> "Started opening Volatile DB"
        ChainDB.StartedOpeningLgrDB -> "Started opening Ledger DB"
        ChainDB.OpenedDB immTip tip' ->
          "Opened db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and tip " <> renderPointAsPhrase tip'
        ChainDB.ClosedDB immTip tip' ->
          "Closed db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and tip " <> renderPointAsPhrase tip'
        ChainDB.OpenedImmutableDB immTip chunk ->
          "Opened imm db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and chunk " <> showT chunk
        ChainDB.OpenedVolatileDB mx ->  "Opened " <> case mx of
          NoMaxSlotNo -> "empty Volatile DB"
          MaxSlotNo mxx -> "Volatile DB with max slot seen " <> showT mxx
        ChainDB.OpenedLgrDB ->  "Opened lgr db"
      ChainDB.TraceFollowerEvent ev -> case ev of
        ChainDB.NewFollower ->  "New follower was created"
        ChainDB.FollowerNoLongerInMem _ ->  "FollowerNoLongerInMem"
        ChainDB.FollowerSwitchToMem _ _ ->  "FollowerSwitchToMem"
        ChainDB.FollowerNewImmIterator _ _ ->  "FollowerNewImmIterator"
      ChainDB.TraceInitChainSelEvent ev -> case ev of
        ChainDB.StartedInitChainSelection -> "Started initial chain selection"
        ChainDB.InitialChainSelected -> "Initial chain selected"
        ChainDB.InitChainSelValidation e -> case e of
          ChainDB.InvalidBlock _err _pt -> "Invalid block found during Initial chain selection, truncating the candidate and retrying to select a best candidate."
          ChainDB.ValidCandidate af     -> "Valid candidate spanning from " <> renderPointAsPhrase (AF.lastPoint af) <> " to " <> renderPointAsPhrase (AF.headPoint af)
          ChainDB.UpdateLedgerDbTraceEvent (LedgerDB.StartedPushingBlockToTheLedgerDb (PushStart start) (PushGoal goal) (Pushing curr)) ->
            let fromSlot = unSlotNo $ realPointSlot start
                atSlot   = unSlotNo $ realPointSlot curr
                atDiff   = atSlot - fromSlot
                toSlot   = unSlotNo $ realPointSlot goal
                toDiff   = toSlot - fromSlot
            in
              "Pushing ledger state for block " <> renderRealPointAsPhrase curr <> ". Progress: " <>
              showProgressT (fromIntegral atDiff) (fromIntegral toDiff) <> "%"
      ChainDB.TraceIteratorEvent ev -> case ev of
        ChainDB.UnknownRangeRequested ev' ->
          case ev' of
            ChainDB.MissingBlock realPt ->
              "The block at the given point was not found in the ChainDB."
              <> renderRealPoint realPt
            ChainDB.ForkTooOld streamFrom ->
              "The requested range forks off too far in the past"
              <> showT streamFrom
        ChainDB.BlockMissingFromVolatileDB realPt -> mconcat
          [ "This block is no longer in the VolatileDB because it has been garbage"
          , " collected. It might now be in the ImmutableDB if it was part of the"
          , " current chain. Block: "
          , renderRealPoint realPt
          ]
        ChainDB.StreamFromImmutableDB sFrom sTo -> mconcat
          [ "Stream only from the ImmutableDB. StreamFrom:"
          , showT sFrom
          , " StreamTo: "
          , showT sTo
          ]
        ChainDB.StreamFromBoth sFrom sTo pts -> mconcat
          [ "Stream from both the VolatileDB and the ImmutableDB."
          , " StreamFrom: " <> showT sFrom <> " StreamTo: " <> showT sTo
          , " Points: " <> showT (map renderRealPoint pts)
          ]
        ChainDB.StreamFromVolatileDB sFrom sTo pts -> mconcat
          [ "Stream only from the VolatileDB."
          , " StreamFrom: " <> showT sFrom <> " StreamTo: " <> showT sTo
          , " Points: " <> showT (map renderRealPoint pts)
          ]
        ChainDB.BlockWasCopiedToImmutableDB pt -> mconcat
          [ "This block has been garbage collected from the VolatileDB is now"
          , " found and streamed from the ImmutableDB. Block: " <> renderRealPoint pt
          ]
        ChainDB.BlockGCedFromVolatileDB pt -> mconcat
          [ "This block no longer in the VolatileDB and isn't in the ImmutableDB"
          , " either; it wasn't part of the current chain. Block: " <> renderRealPoint pt
          ]
        ChainDB.SwitchBackToVolatileDB ->  "SwitchBackToVolatileDB"
      ChainDB.TraceImmutableDBEvent ev -> case ev of
        ImmDB.NoValidLastLocation ->
          "No valid last location was found. Starting from Genesis."
        ImmDB.ValidatedLastLocation cn t ->
            "Found a valid last location at chunk "
          <> showT cn
          <> " with tip "
          <> renderRealPoint (ImmDB.tipToRealPoint t)
          <> "."
        ImmDB.ChunkValidationEvent e -> case e of
          ImmDB.StartedValidatingChunk chunkNo outOf ->
               "Validating chunk no. " <> showT chunkNo <> " out of " <> showT outOf
            <> ". Progress: " <> showProgressT (chunkNoToInt chunkNo) (chunkNoToInt outOf + 1) <> "%"
          ImmDB.ValidatedChunk chunkNo outOf ->
               "Validated chunk no. " <> showT chunkNo <> " out of " <> showT outOf
            <> ". Progress: " <> showProgressT (chunkNoToInt chunkNo + 1) (chunkNoToInt outOf + 1) <> "%"
          ImmDB.MissingChunkFile cn      ->
            "The chunk file with number " <> showT cn <> " is missing."
          ImmDB.InvalidChunkFile cn er    ->
            "The chunk file with number " <> showT cn <> " is invalid: " <> showT er
          ImmDB.MissingPrimaryIndex cn   ->
            "The primary index of the chunk file with number " <> showT cn <> " is missing."
          ImmDB.MissingSecondaryIndex cn ->
            "The secondary index of the chunk file with number " <> showT cn <> " is missing."
          ImmDB.InvalidPrimaryIndex cn   ->
            "The primary index of the chunk file with number " <> showT cn <> " is invalid."
          ImmDB.InvalidSecondaryIndex cn ->
            "The secondary index of the chunk file with number " <> showT cn <> " is invalid."
          ImmDB.RewritePrimaryIndex cn   ->
            "Rewriting the primary index for the chunk file with number " <> showT cn <> "."
          ImmDB.RewriteSecondaryIndex cn ->
            "Rewriting the secondary index for the chunk file with number " <> showT cn <> "."
        ImmDB.ChunkFileDoesntFit ch1 ch2 ->
          "Chunk file doesn't fit. The hash of the block " <> showT ch2 <> " doesn't match the previous hash of the first block in the current epoch: " <> showT ch1 <> "."
        ImmDB.Migrating t -> "Migrating: " <> t
        ImmDB.DeletingAfter wot -> "Deleting chunk files after " <> showT wot
        ImmDB.DBAlreadyClosed {} -> "Immutable DB was already closed. Double closing."
        ImmDB.DBClosed {} -> "Closed Immutable DB."
        ImmDB.TraceCacheEvent ev' -> "Cache event: " <> case ev' of
          ImmDB.TraceCurrentChunkHit   cn   curr -> "Current chunk hit: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunkHit      cn   curr -> "Past chunk hit: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunkMiss     cn   curr -> "Past chunk miss: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunkEvict    cn   curr -> "Past chunk evict: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunksExpired cns  curr -> "Past chunks expired: " <> showT cns <> ", cache size: " <> showT curr
      ChainDB.TraceVolatileDBEvent ev -> case ev of
        VolDb.DBAlreadyClosed       -> "Volatile DB was already closed. Double closing."
        VolDb.BlockAlreadyHere bh   -> "Block " <> showT bh <> " was already in the Volatile DB."
        VolDb.Truncate e pth offs   -> "Truncating the file at " <> showT pth <> " at offset " <> showT offs <> ": " <> showT e
        VolDb.InvalidFileNames fs   -> "Invalid Volatile DB files: " <> showT fs
        VolDb.DBClosed              -> "Closed Volatile DB."
      ChainDB.TraceChainSelStarvationEvent ev -> case ev of
        ChainDB.ChainSelStarvation RisingEdge -> "Chain Selection was starved."
        ChainDB.ChainSelStarvation (FallingEdgeWith pt) -> "Chain Selection was unstarved by " <> renderRealPoint pt
     where showProgressT :: Int -> Int -> Text
           showProgressT chunkNo outOf =
             pack (showFFloat (Just 2) (100 * fromIntegral chunkNo / fromIntegral outOf :: Float) mempty)

--
-- | instances of @ToObject@
--
-- NOTE: this list is sorted by the unqualified name of the outermost type.

instance ToObject BFT.BftValidationErr where
  toObject _verb (BFT.BftInvalidSignature err) =
    mconcat
      [ "kind" .= String "BftInvalidSignature"
      , "error" .= String (pack err)
      ]


instance ToObject LedgerDB.DiskSnapshot where
  toObject MinimalVerbosity snap = toObject NormalVerbosity snap
  toObject NormalVerbosity _ = mconcat [ "kind" .= String "snapshot" ]
  toObject MaximalVerbosity snap =
    mconcat [ "kind" .= String "snapshot"
             , "snapshot" .= String (pack $ show snap) ]


instance ( StandardHash blk
         , ToObject (LedgerError blk)
         , ToObject (OtherHeaderEnvelopeError blk)
         , ToObject (ValidationErr (BlockProtocol blk)))
      => ToObject (ExtValidationError blk) where
  toObject verb (ExtValidationErrorLedger err) = toObject verb err
  toObject verb (ExtValidationErrorHeader err) = toObject verb err


instance ( StandardHash blk
         , ToObject (OtherHeaderEnvelopeError blk)
         )
      => ToObject (HeaderEnvelopeError blk) where
  toObject _verb (UnexpectedBlockNo expect act) =
    mconcat
      [ "kind" .= String "UnexpectedBlockNo"
      , "expected" .= condense expect
      , "actual" .= condense act
      ]
  toObject _verb (UnexpectedSlotNo expect act) =
    mconcat
      [ "kind" .= String "UnexpectedSlotNo"
      , "expected" .= condense expect
      , "actual" .= condense act
      ]
  toObject _verb (UnexpectedPrevHash expect act) =
    mconcat
      [ "kind" .= String "UnexpectedPrevHash"
      , "expected" .= String (pack $ show expect)
      , "actual" .= String (pack $ show act)
      ]
  toObject _verb (CheckpointMismatch blockNumber hdrHashExpected hdrHashActual) =
    mconcat
      [ "kind" .= String "CheckpointMismatch"
      , "blockNo" .= String (pack $ show blockNumber)
      , "expected" .= String (pack $ show hdrHashExpected)
      , "actual" .= String (pack $ show hdrHashActual)
      ]
  toObject verb (OtherHeaderEnvelopeError err) =
    toObject verb err


instance ( StandardHash blk
         , ToObject (ValidationErr (BlockProtocol blk))
         , ToObject (OtherHeaderEnvelopeError blk)
         )
      => ToObject (HeaderError blk) where
  toObject verb (HeaderProtocolError err) =
    mconcat
      [ "kind" .= String "HeaderProtocolError"
      , "error" .= toObject verb err
      ]
  toObject verb (HeaderEnvelopeError err) =
    mconcat
      [ "kind" .= String "HeaderEnvelopeError"
      , "error" .= toObject verb err
      ]


instance (Show (PBFT.PBftVerKeyHash c))
      => ToObject (PBFT.PBftValidationErr c) where
  toObject _verb (PBFT.PBftInvalidSignature text) =
    mconcat
      [ "kind" .= String "PBftInvalidSignature"
      , "error" .= String text
      ]
  toObject _verb (PBFT.PBftNotGenesisDelegate vkhash _ledgerView) =
    mconcat
      [ "kind" .= String "PBftNotGenesisDelegate"
      , "vk" .= String (pack $ show vkhash)
      ]
  toObject _verb (PBFT.PBftExceededSignThreshold vkhash numForged) =
    mconcat
      [ "kind" .= String "PBftExceededSignThreshold"
      , "vk" .= String (pack $ show vkhash)
      , "numForged" .= String (pack (show numForged))
      ]
  toObject _verb PBFT.PBftInvalidSlot =
    mconcat
      [ "kind" .= String "PBftInvalidSlot"
      ]


instance (Show (PBFT.PBftVerKeyHash c))
      => ToObject (PBFT.PBftCannotForge c) where
  toObject _verb (PBFT.PBftCannotForgeInvalidDelegation vkhash) =
    mconcat
      [ "kind" .= String "PBftCannotForgeInvalidDelegation"
      , "vk" .= String (pack $ show vkhash)
      ]
  toObject _verb (PBFT.PBftCannotForgeThresholdExceeded numForged) =
    mconcat
      [ "kind" .= String "PBftCannotForgeThresholdExceeded"
      , "numForged" .= numForged
      ]


instance ConvertRawHash blk
      => ToObject (RealPoint blk) where
  toObject verb p = mconcat
        [ "kind" .= String "Point"
        , "slot" .= unSlotNo (realPointSlot p)
        , "hash" .= renderHeaderHashForVerbosity (Proxy @blk) verb (realPointHash p) ]


instance (ToObject (LedgerUpdate blk), ToObject (LedgerWarning blk))
      => ToObject (LedgerEvent blk) where
  toObject verb = \case
    LedgerUpdate  update  -> toObject verb update
    LedgerWarning warning -> toObject verb warning


instance ( ConvertRawHash blk
         , LedgerSupportsProtocol blk
         , ToObject (Header blk)
         , ToObject (LedgerEvent blk)
         , ToObject (SelectView (BlockProtocol blk)))
      => ToObject (ChainDB.TraceEvent blk) where
  toObject _verb ChainDB.TraceLastShutdownUnclean =
    mconcat [ "kind" .= String "TraceLastShutdownUnclean" ]
  toObject verb (ChainDB.TraceAddBlockEvent ev) = case ev of
    ChainDB.IgnoreBlockOlderThanK pt ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.IgnoreBlockOlderThanK"
               , "block" .= toObject verb pt ]
    ChainDB.IgnoreBlockAlreadyInVolatileDB pt ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.IgnoreBlockAlreadyInVolatileDB"
               , "block" .= toObject verb pt ]
    ChainDB.IgnoreInvalidBlock pt reason ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.IgnoreInvalidBlock"
               , "block" .= toObject verb pt
               , "reason" .= show reason ]
    ChainDB.AddedBlockToQueue pt edgeSz ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.AddedBlockToQueue"
               , "block" .= toObject verb pt
               , case edgeSz of
                   RisingEdge         -> "risingEdge" .= True
                   FallingEdgeWith sz -> "queueSize" .= toJSON sz ]
    ChainDB.PoppedBlockFromQueue edgePt ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.PoppedBlockFromQueue"
               , case edgePt of
                   RisingEdge         -> "risingEdge" .= True
                   FallingEdgeWith pt -> "block" .= toObject verb pt ]
    ChainDB.StoreButDontChange pt ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.StoreButDontChange"
               , "block" .= toObject verb pt ]
    ChainDB.TryAddToCurrentChain pt ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.TryAddToCurrentChain"
               , "block" .= toObject verb pt ]
    ChainDB.TrySwitchToAFork pt _ ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.TrySwitchToAFork"
               , "block" .= toObject verb pt ]
    ChainDB.ChangingSelection pt ->
      mconcat [ "kind" .= String "TraceAddBlockEvent.ChangingSelection"
               , "block" .= toObject verb pt ]
    ChainDB.AddedToCurrentChain events selChangedInfo base extended ->
      mconcat $
               [ "kind" .= String "TraceAddBlockEvent.AddedToCurrentChain"
               , "newtip" .= renderPointForVerbosity verb (AF.headPoint extended)
               , "chainLengthDelta" .= extended `chainLengthΔ` base
               , "newTipSelectView" .= toObject verb (ChainDB.newTipSelectView selChangedInfo)
               ]
            ++ [ "oldTipSelectView" .= toObject verb oldTipSelectView
               | Just oldTipSelectView <- [ChainDB.oldTipSelectView selChangedInfo]
               ]
            ++ [ "headers" .= toJSON (toObject verb `map` addedHdrsNewChain base extended)
               | verb == MaximalVerbosity ]
            ++ [ "events" .= toJSON (map (toObject verb) events)
               | not (null events) ]
    ChainDB.SwitchedToAFork events selChangedInfo old new ->
      mconcat $
               [ "kind" .= String "TraceAddBlockEvent.SwitchedToAFork"
               , "newtip" .= renderPointForVerbosity verb (AF.headPoint new)
               , "chainLengthDelta" .= new `chainLengthΔ` old
               -- Check that the SwitchedToAFork event was triggered by a proper fork.
               , "realFork" .= not (AF.withinFragmentBounds (AF.headPoint old) new)
               , "newTipSelectView" .= toObject verb (ChainDB.newTipSelectView selChangedInfo)
               ]
            ++ [ "oldTipSelectView" .= toObject verb oldTipSelectView
               | Just oldTipSelectView <- [ChainDB.oldTipSelectView selChangedInfo]
               ]
            ++ [ "headers" .= toJSON (toObject verb `map` addedHdrsNewChain old new)
               | verb == MaximalVerbosity ]
            ++ [ "events" .= toJSON (map (toObject verb) events)
               | not (null events) ]
    ChainDB.AddBlockValidation ev' -> case ev' of
      ChainDB.InvalidBlock err pt ->
        mconcat [ "kind" .= String "TraceAddBlockEvent.AddBlockValidation.InvalidBlock"
                 , "block" .= toObject verb pt
                 , "error" .= show err ]
      ChainDB.ValidCandidate c ->
        mconcat [ "kind" .= String "TraceAddBlockEvent.AddBlockValidation.ValidCandidate"
                 , "block" .= renderPointForVerbosity verb (AF.headPoint c) ]
      ChainDB.UpdateLedgerDbTraceEvent (LedgerDB.StartedPushingBlockToTheLedgerDb (PushStart start) (PushGoal goal) (Pushing curr)) ->
        mconcat [ "kind" .= String "TraceAddBlockEvent.AddBlockValidation.UpdateLedgerDb"
                 , "startingBlock" .= renderRealPoint start
                 , "currentBlock" .= renderRealPoint curr
                 , "targetBlock" .= renderRealPoint goal
                 ]
    ChainDB.AddedBlockToVolatileDB pt (BlockNo bn) _isEBB enclosing ->
      mconcat $ [ "kind" .= String "TraceAddBlockEvent.AddedBlockToVolatileDB"
                , "block" .= toObject verb pt
                , "blockNo" .= show bn ]
                <> [ "risingEdge" .= True | RisingEdge <- [enclosing] ]
    ChainDB.PipeliningEvent ev' -> case ev' of
      ChainDB.SetTentativeHeader hdr enclosing ->
        mconcat $ [ "kind" .= String "TraceAddBlockEvent.PipeliningEvent.SetTentativeHeader"
                  , "block" .= renderPointForVerbosity verb (blockPoint hdr)
                  ]
                  <> [ "risingEdge" .= True | RisingEdge <- [enclosing] ]
      ChainDB.TrapTentativeHeader hdr ->
        mconcat [ "kind" .= String "TraceAddBlockEvent.PipeliningEvent.TrapTentativeHeader"
                 , "block" .= renderPointForVerbosity verb (blockPoint hdr)
                 ]
      ChainDB.OutdatedTentativeHeader hdr ->
        mconcat [ "kind" .= String "TraceAddBlockEvent.PipeliningEvent.OutdatedTentativeHeader"
                 , "block" .= renderPointForVerbosity verb (blockPoint hdr)
                 ]
    ChainDB.AddedReprocessLoEBlocksToQueue ->
       mconcat [ "kind" .= String "AddedReprocessLoEBlocksToQueue" ]
    ChainDB.PoppedReprocessLoEBlocksFromQueue ->
       mconcat [ "kind" .= String "PoppedReprocessLoEBlocksFromQueue" ]
    ChainDB.ChainSelectionLoEDebug curChain loeFrag ->
      case loeFrag of
        ChainDB.LoEEnabled loeF ->
          mconcat [ "kind" .= String "ChainSelectionLoEDebug"
                  , "curChain" .= headAndAnchor curChain
                  , "loeFrag" .= headAndAnchor loeF
                  ]
        ChainDB.LoEDisabled ->
          mconcat [ "kind" .= String "ChainSelectionLoEDebug"
                  , "curChain" .= headAndAnchor curChain
                  , "loeFrag" .= String "LoE is disabled"
                  ]
      where
        headAndAnchor frag = Aeson.object
          [ "anchor" .= renderPointForVerbosity verb (AF.anchorPoint frag)
          , "head" .= renderPointForVerbosity verb (AF.headPoint frag)
          ]
   where
     addedHdrsNewChain
       :: AF.AnchoredFragment (Header blk)
       -> AF.AnchoredFragment (Header blk)
       -> [Header blk]
     addedHdrsNewChain fro to_ =
       case AF.intersect fro to_ of
         Just (_, _, _, s2 :: AF.AnchoredFragment (Header blk)) ->
           AF.toOldestFirst s2
         Nothing -> [] -- No sense to do validation here.
     chainLengthΔ :: AF.AnchoredFragment (Header blk) -> AF.AnchoredFragment (Header blk) -> Int
     chainLengthΔ = on (-) (fromWithOrigin (-1) . fmap (fromIntegral . unBlockNo) . AF.headBlockNo)

  toObject MinimalVerbosity (ChainDB.TraceLedgerDBEvent _ev) = mempty -- no output
  toObject verb (ChainDB.TraceLedgerDBEvent ev) = case ev of
    LedgerDB.LedgerDBSnapshotEvent ev' -> case ev' of
      LedgerDB.TookSnapshot snap pt enclosedTiming ->
        mconcat [ "kind" .= String "TraceSnapshotEvent.TookSnapshot"
                 , "snapshot" .= toObject verb snap
                 , "tip" .= show pt
                 , "enclosedTime" .= enclosedTiming
                 ]
      LedgerDB.DeletedSnapshot snap ->
        mconcat [ "kind" .= String "TraceLedgerDBEvent.LedgerDBSnapshotEvent.DeletedSnapshot"
                 , "snapshot" .= toObject verb snap ]
      LedgerDB.InvalidSnapshot snap failure ->
        mconcat [ "kind" .= String "TraceLedgerDBEvent.LedgerDBSnapshotEvent.InvalidSnapshot"
                 , "snapshot" .= toObject verb snap
                 , "failure" .= show failure ]
    LedgerDB.LedgerReplayEvent ev' -> case ev' of
      LedgerDB.TraceReplayStartEvent ev'' -> case ev'' of
        LedgerDB.ReplayFromGenesis ->
          mconcat [ "kind" .= String "TraceLedgerReplayEvent.ReplayFromGenesis" ]
        LedgerDB.ReplayFromSnapshot snap tip' ->
          mconcat [ "kind" .= String "TraceLedgerReplayEvent.ReplayFromSnapshot"
                  , "snapshot" .= toObject verb snap
                  , "tip" .= show tip' ]
      LedgerDB.TraceReplayProgressEvent (LedgerDB.ReplayedBlock pt _ledgerEvents _ (LedgerDB.ReplayGoal replayTo)) ->
        mconcat [ "kind" .= String "TraceLedgerReplayEvent.ReplayedBlock"
                , "slot" .= unSlotNo (realPointSlot pt)
                , "tip"  .= withOrigin 0 unSlotNo (pointSlot replayTo) ]
    LedgerDB.LedgerDBForkerEvent (LedgerDB.TraceForkerEventWithKey k ev') ->
      mconcat [ "kind" .= String "LedgerDBForkerEvent"
              , "key" .= show k
              , "event" .= show ev' ]
    LedgerDB.LedgerDBFlavorImplEvent ev' ->
      mconcat [ "kind" .= String "LedgerDBFlavorImplEvent"
              , "event" .= show ev' ]

  toObject verb (ChainDB.TraceCopyToImmutableDBEvent ev) = case ev of
    ChainDB.CopiedBlockToImmutableDB pt ->
      mconcat [ "kind" .= String "TraceCopyToImmutableDBEvent.CopiedBlockToImmutableDB"
               , "slot" .= toObject verb pt ]
    ChainDB.NoBlocksToCopyToImmutableDB ->
      mconcat [ "kind" .= String "TraceCopyToImmutableDBEvent.NoBlocksToCopyToImmutableDB" ]

  toObject verb (ChainDB.TraceGCEvent ev) = case ev of
    ChainDB.PerformedGC slot ->
      mconcat [ "kind" .= String "TraceGCEvent.PerformedGC"
               , "slot" .= toObject verb slot ]
    ChainDB.ScheduledGC slot difft ->
      mconcat $ [ "kind" .= String "TraceGCEvent.ScheduledGC"
                 , "slot" .= toObject verb slot ] <>
                 [ "difft" .= String ((pack . show) difft) | verb >= MaximalVerbosity]

  toObject verb (ChainDB.TraceOpenEvent ev) = case ev of
    ChainDB.StartedOpeningDB ->
      mconcat ["kind" .= String "TraceOpenEvent.StartedOpeningDB"]
    ChainDB.StartedOpeningImmutableDB ->
      mconcat ["kind" .= String "TraceOpenEvent.StartedOpeningImmutableDB"]
    ChainDB.StartedOpeningVolatileDB ->
      mconcat ["kind" .= String "TraceOpenEvent.StartedOpeningVolatileDB"]
    ChainDB.StartedOpeningLgrDB ->
      mconcat ["kind" .= String "TraceOpenEvent.StartedOpeningLgrDB"]
    ChainDB.OpenedDB immTip tip' ->
      mconcat [ "kind" .= String "TraceOpenEvent.OpenedDB"
               , "immtip" .= toObject verb immTip
               , "tip" .= toObject verb tip' ]
    ChainDB.ClosedDB immTip tip' ->
      mconcat [ "kind" .= String "TraceOpenEvent.ClosedDB"
               , "immtip" .= toObject verb immTip
               , "tip" .= toObject verb tip' ]
    ChainDB.OpenedImmutableDB immTip epoch ->
      mconcat [ "kind" .= String "TraceOpenEvent.OpenedImmutableDB"
               , "immtip" .= toObject verb immTip
               , "epoch" .= String ((pack . show) epoch) ]
    ChainDB.OpenedVolatileDB maxSlotN ->
      mconcat [ "kind" .= String "TraceOpenEvent.OpenedVolatileDB"
               , "maxSlotNo" .= String (showT maxSlotN) ]
    ChainDB.OpenedLgrDB ->
      mconcat [ "kind" .= String "TraceOpenEvent.OpenedLgrDB" ]

  toObject _verb (ChainDB.TraceFollowerEvent ev) = case ev of
    ChainDB.NewFollower ->
      mconcat [ "kind" .= String "TraceFollowerEvent.NewFollower" ]
    ChainDB.FollowerNoLongerInMem _ ->
      mconcat [ "kind" .= String "TraceFollowerEvent.FollowerNoLongerInMem" ]
    ChainDB.FollowerSwitchToMem _ _ ->
      mconcat [ "kind" .= String "TraceFollowerEvent.FollowerSwitchToMem" ]
    ChainDB.FollowerNewImmIterator _ _ ->
      mconcat [ "kind" .= String "TraceFollowerEvent.FollowerNewImmIterator" ]
  toObject verb (ChainDB.TraceInitChainSelEvent ev) = case ev of
    ChainDB.InitialChainSelected ->
      mconcat ["kind" .= String "TraceFollowerEvent.InitialChainSelected"]
    ChainDB.StartedInitChainSelection ->
      mconcat ["kind" .= String "TraceFollowerEvent.StartedInitChainSelection"]
    ChainDB.InitChainSelValidation ev' -> case ev' of
      ChainDB.InvalidBlock err pt ->
         mconcat [ "kind" .= String "TraceInitChainSelEvent.InvalidBlock"
                  , "block" .= toObject verb pt
                  , "error" .= show err ]
      ChainDB.ValidCandidate c ->
        mconcat [ "kind" .= String "TraceInitChainSelEvent.ValidCandidate"
                 , "block" .= renderPointForVerbosity verb (AF.headPoint c) ]
      ChainDB.UpdateLedgerDbTraceEvent
        (LedgerDB.StartedPushingBlockToTheLedgerDb (PushStart start) (PushGoal goal) (Pushing curr) ) ->
          mconcat [ "kind" .= String "TraceAddBlockEvent.AddBlockValidation.UpdateLedgerDbTraceEvent.StartedPushingBlockToTheLedgerDb"
                   , "startingBlock" .= renderRealPoint start
                   , "currentBlock" .= renderRealPoint curr
                   , "targetBlock" .= renderRealPoint goal
                   ]

  toObject _verb (ChainDB.TraceIteratorEvent ev) = case ev of
    ChainDB.UnknownRangeRequested unkRange ->
      mconcat [ "kind" .= String "TraceIteratorEvent.UnknownRangeRequested"
               , "range" .= String (showT unkRange)
               ]
    ChainDB.StreamFromVolatileDB streamFrom streamTo realPt ->
      mconcat [ "kind" .= String "TraceIteratorEvent.StreamFromVolatileDB"
               , "from" .= String (showT streamFrom)
               , "to" .= String (showT streamTo)
               , "point" .= String (Text.pack . show $ map renderRealPoint realPt)
               ]
    ChainDB.StreamFromImmutableDB streamFrom streamTo ->
      mconcat [ "kind" .= String "TraceIteratorEvent.StreamFromImmutableDB"
               , "from" .= String (showT streamFrom)
               , "to" .= String (showT streamTo)
               ]
    ChainDB.StreamFromBoth streamFrom streamTo realPt ->
      mconcat [ "kind" .= String "TraceIteratorEvent.StreamFromBoth"
               , "from" .= String (showT streamFrom)
               , "to" .= String (showT streamTo)
               , "point" .= String (Text.pack . show $ map renderRealPoint realPt)
               ]
    ChainDB.BlockMissingFromVolatileDB realPt ->
      mconcat [ "kind" .= String "TraceIteratorEvent.BlockMissingFromVolatileDB"
               , "point" .= String (renderRealPoint realPt)
               ]
    ChainDB.BlockWasCopiedToImmutableDB realPt ->
      mconcat [ "kind" .= String "TraceIteratorEvent.BlockWasCopiedToImmutableDB"
               , "point" .= String (renderRealPoint realPt)
               ]
    ChainDB.BlockGCedFromVolatileDB realPt ->
      mconcat [ "kind" .= String "TraceIteratorEvent.BlockGCedFromVolatileDB"
               , "point" .= String (renderRealPoint realPt)
               ]
    ChainDB.SwitchBackToVolatileDB ->
      mconcat ["kind" .= String "TraceIteratorEvent.SwitchBackToVolatileDB"
               ]
  toObject verb (ChainDB.TraceImmutableDBEvent ev) = case ev of
    ImmDB.ChunkValidationEvent traceChunkValidation -> toObject verb traceChunkValidation
    ImmDB.NoValidLastLocation ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.NoValidLastLocation" ]
    ImmDB.ValidatedLastLocation chunkNo immTip ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.ValidatedLastLocation"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               , "immTip" .= String (renderTipHash immTip)
               , "blockNo" .= String (renderTipBlockNo immTip)
               ]
    ImmDB.ChunkFileDoesntFit expectPrevHash actualPrevHash ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.ChunkFileDoesntFit"
               , "expectedPrevHash" .= String (renderChainHash (Text.decodeLatin1 . toRawHash (Proxy @blk)) expectPrevHash)
               , "actualPrevHash" .= String (renderChainHash (Text.decodeLatin1 . toRawHash (Proxy @blk)) actualPrevHash)
               ]
    ImmDB.Migrating txt ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.Migrating"
               , "info" .= String txt
               ]
    ImmDB.DeletingAfter immTipWithInfo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.DeletingAfter"
               , "immTipHash" .= String (renderWithOrigin renderTipHash immTipWithInfo)
               , "immTipBlockNo" .= String (renderWithOrigin renderTipBlockNo immTipWithInfo)
               ]
    ImmDB.DBAlreadyClosed -> mconcat [ "kind" .= String "TraceImmutableDBEvent.DBAlreadyClosed" ]
    ImmDB.DBClosed -> mconcat [ "kind" .= String "TraceImmutableDBEvent.DBClosed" ]
    ImmDB.TraceCacheEvent cacheEv ->
      case cacheEv of
        ImmDB.TraceCurrentChunkHit chunkNo nbPastChunksInCache ->
          mconcat [ "kind" .= String "TraceImmDbEvent.TraceCacheEvent.TraceCurrentChunkHit"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
        ImmDB.TracePastChunkHit chunkNo nbPastChunksInCache ->
          mconcat [ "kind" .= String "TraceImmDbEvent.TraceCacheEvent.TracePastChunkHit"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
        ImmDB.TracePastChunkMiss chunkNo nbPastChunksInCache ->
          mconcat [ "kind" .= String "TraceImmDbEvent.TraceCacheEvent.TracePastChunkMiss"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
        ImmDB.TracePastChunkEvict chunkNo nbPastChunksInCache ->
          mconcat [ "kind" .= String "TraceImmDbEvent.TraceCacheEvent.TracePastChunkEvict"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
        ImmDB.TracePastChunksExpired chunkNos nbPastChunksInCache ->
          mconcat [ "kind" .= String "TraceImmDbEvent.TraceCacheEvent.TracePastChunksExpired"
                   , "chunkNos" .= String (Text.pack . show $ map renderChunkNo chunkNos)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
  toObject _verb (ChainDB.TraceVolatileDBEvent ev) = case ev of
    VolDb.DBAlreadyClosed -> mconcat [ "kind" .= String "TraceVolatileDbEvent.DBAlreadyClosed"]
    VolDb.BlockAlreadyHere blockId ->
      mconcat [ "kind" .= String "TraceVolatileDbEvent.BlockAlreadyHere"
               , "blockId" .= String (showT blockId)
               ]
    VolDb.Truncate pErr fsPath blockOffset ->
      mconcat [ "kind" .= String "TraceVolatileDbEvent.Truncate"
               , "parserError" .= String (showT pErr)
               , "file" .= String (showT fsPath)
               , "blockOffset" .= String (showT blockOffset)
               ]
    VolDb.InvalidFileNames fsPaths ->
      mconcat [ "kind" .= String "TraceVolatileDBEvent.InvalidFileNames"
               , "files" .= String (Text.pack . show $ map show fsPaths)
               ]
    VolDb.DBClosed -> mconcat [ "kind" .= String "TraceVolatileDbEvent.DBClosed"]
  toObject verb (ChainDB.TraceChainSelStarvationEvent (ChainDB.ChainSelStarvation edge)) =
     mconcat [ "kind" .= String "ChainDB.ChainSelStarvation"
             , case edge of
                 RisingEdge -> "risingEdge" .= True
                 FallingEdgeWith pt -> "fallingEdge" .= toObject verb pt
             ]

instance ConvertRawHash blk => ToObject (ImmDB.TraceChunkValidation blk ChunkNo) where
  toObject verb ev = case ev of
    ImmDB.RewriteSecondaryIndex chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.RewriteSecondaryIndex"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.RewritePrimaryIndex chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.RewritePrimaryIndex"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.MissingPrimaryIndex chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.MissingPrimaryIndex"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.MissingSecondaryIndex chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.MissingSecondaryIndex"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.InvalidPrimaryIndex chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidPrimaryIndex"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.InvalidSecondaryIndex chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidSecondaryIndex"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.InvalidChunkFile chunkNo (ImmDB.ChunkErrHashMismatch hashPrevBlock prevHashOfBlock) ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidChunkFile.ChunkErrHashMismatch"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               , "hashPrevBlock" .= String (Text.decodeLatin1 . toRawHash (Proxy @blk) $ hashPrevBlock)
               , "prevHashOfBlock" .= String (renderChainHash (Text.decodeLatin1 . toRawHash (Proxy @blk)) prevHashOfBlock)
               ]
    ImmDB.InvalidChunkFile chunkNo (ImmDB.ChunkErrCorrupt pt) ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidChunkFile.ChunkErrCorrupt"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               , "block" .= String (renderPointForVerbosity verb pt)
               ]
    ImmDB.ValidatedChunk chunkNo _ ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.ValidatedChunk"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.MissingChunkFile chunkNo ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.MissingChunkFile"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               ]
    ImmDB.InvalidChunkFile chunkNo (ImmDB.ChunkErrRead readIncErr) ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidChunkFile.ChunkErrRead"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               , "error" .= String (showT readIncErr)
               ]
    ImmDB.StartedValidatingChunk initialChunk finalChunk ->
      mconcat [ "kind" .= String "TraceImmutableDBEvent.StartedValidatingChunk"
               , "initialChunk" .= renderChunkNo initialChunk
               , "finalChunk" .= renderChunkNo finalChunk
               ]


instance ConvertRawHash blk => ToObject (TraceBlockFetchServerEvent blk) where
  toObject _verb (TraceBlockFetchServerSendBlock blk) =
    mconcat [ "kind"  .= String "TraceBlockFetchServerSendBlock"
             , "block" .= String (renderChainHash @blk (renderHeaderHash (Proxy @blk)) $ pointHash blk)
             ]

tipToObject :: forall blk. ConvertRawHash blk => Tip blk -> Aeson.Object
tipToObject = \case
  TipGenesis -> mconcat
    [ "slot"    .= toJSON (0 :: Int)
    , "block"   .= String "genesis"
    , "blockNo" .= toJSON ((-1) :: Int)
    ]
  Tip slot hash blockno -> mconcat
    [ "slot"    .= slot
    , "block"   .= String (renderHeaderHash (Proxy @blk) hash)
    , "blockNo" .= blockno
    ]

instance (ConvertRawHash blk, LedgerSupportsProtocol blk)
      => ToObject (TraceChainSyncClientEvent blk) where
  toObject verb ev = case ev of
    TraceDownloadedHeader h ->
      mconcat
               [ "kind" .= String "ChainSyncClientEvent.TraceDownloadedHeader"
               , tipToObject (tipFromHeader h)
               ]
    TraceRolledBack tip ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceRolledBack"
               , "tip" .= toObject verb tip ]
    TraceException exc ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceException"
               , "exception" .= String (pack $ show exc) ]
    TraceFoundIntersection _ _ _ ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceFoundIntersection" ]
    TraceTermination reason ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceTermination"
               , "reason" .= String (pack $ show reason) ]
    TraceValidatedHeader h ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceValidatedHeader"
              , tipToObject (tipFromHeader h) ]
    TraceWaitingBeyondForecastHorizon slotNo ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceWaitingBeyondForecastHorizon"
               , "slot" .= condense slotNo  ]
    TraceAccessingForecastHorizon slotNo ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceAccessingForecastHorizon"
               , "slot" .= condense slotNo  ]
    TraceGaveLoPToken tokenGiven h bestBlockNumberPriorToH ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceGaveLoPToken"
               , "given" .= tokenGiven
               , tipToObject (tipFromHeader h)
               , "blockNo" .=  bestBlockNumberPriorToH ]
    TraceOfferJump jumpTo ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceOfferJump"
               , "jumpTo" .= toObject verb jumpTo
               ]
    TraceJumpResult res ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceJumpResult"
               , "res" .= case res of
                   ChainSync.Client.AcceptedJump info -> Aeson.object
                     [ "kind" .= String "AcceptedJump"
                      , "payload" .= toObject verb info ]
                   ChainSync.Client.RejectedJump info -> Aeson.object
                     [ "kind" .= String "RejectedJump"
                      , "payload" .= toObject verb info ]
               ]
    TraceJumpingWaitingForNextInstruction ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceJumpingWaitingForNextInstruction"
               ]
    TraceJumpingInstructionIs instr ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceJumpingInstructionIs"
               , "instr" .= toObject verb instr
               ]
    TraceDrainingThePipe n ->
      mconcat [ "kind" .= String "ChainSyncClientEvent.TraceDrainingThePipe"
               , "n" .= natToInt n
               ]

instance ( LedgerSupportsProtocol blk,
           ConvertRawHash blk
         ) => ToObject (ChainSync.Client.Instruction blk) where
  toObject verb = \case
    ChainSync.Client.RunNormally ->
      mconcat ["kind" .= String "RunNormally"]
    ChainSync.Client.Restart ->
      mconcat ["kind" .= String "Restart"]
    ChainSync.Client.JumpInstruction info ->
      mconcat [ "kind" .= String "JumpInstruction"
              , "payload" .= toObject verb info
              ]

instance ( LedgerSupportsProtocol blk,
           ConvertRawHash blk
         ) => ToObject (ChainSync.Client.JumpInstruction blk) where
  toObject verb = \case
    ChainSync.Client.JumpTo info ->
      mconcat [ "kind" .= String "JumpTo"
                , "info" .= toObject verb info ]
    ChainSync.Client.JumpToGoodPoint info ->
      mconcat [ "kind" .= String "JumpToGoodPoint"
                , "info" .= toObject verb info ]

instance ( LedgerSupportsProtocol blk,
           ConvertRawHash blk
         ) => ToObject (ChainSync.Client.JumpInfo blk) where
  toObject verb info =
    mconcat [ "kind" .= String "JumpInfo"
              , "mostRecentIntersection" .= toObject verb (ChainSync.Client.jMostRecentIntersection info)
              , "ourFragment" .= toJSON ((tipToObject . tipFromHeader) `map` AF.toOldestFirst (ChainSync.Client.jOurFragment info))
              , "theirFragment" .= toJSON ((tipToObject . tipFromHeader) `map` AF.toOldestFirst (ChainSync.Client.jTheirFragment info))
              ]

instance HasPrivacyAnnotation (ChainSync.Client.TraceEventCsj peer blk) where
instance HasSeverityAnnotation (ChainSync.Client.TraceEventCsj peer blk) where
  getSeverityAnnotation _ = Debug
instance (ToObject peer, ConvertRawHash blk)
      => Transformable Text IO (TraceLabelPeer peer (ChainSync.Client.TraceEventCsj peer blk)) where
  trTransformer = trStructured
instance (ToObject peer, ConvertRawHash blk)
      => ToObject (ChainSync.Client.TraceEventCsj peer blk) where
    toObject verb = \case
      ChainSync.Client.BecomingObjector prevObjector ->
        mconcat
          [ "kind" .= String "BecomingObjector"
          , "previousObjector" .= (toObject verb <$> prevObjector)
          ]
      ChainSync.Client.BlockedOnJump ->
        mconcat
          [ "kind" .= String "BlockedOnJump"
          ]
      ChainSync.Client.InitializedAsDynamo ->
        mconcat
          [ "kind" .= String "InitializedAsDynamo"
          ]
      ChainSync.Client.NoLongerDynamo newDynamo reason ->
        mconcat
          [ "kind" .= String "NoLongerDynamo"
          , "newDynamo" .= (toObject verb <$> newDynamo)
          , "reason" .= csjReasonToJSON reason
          ]
      ChainSync.Client.NoLongerObjector newObjector reason ->
        mconcat
          [ "kind" .= String "NoLongerObjector"
          , "newObjector" .= (toObject verb <$> newObjector)
          , "reason" .= csjReasonToJSON reason
          ]
      ChainSync.Client.SentJumpInstruction jumpTarget ->
        mconcat
          [ "kind" .= String "SentJumpInstruction"
          , "jumpTarget" .= toObject verb jumpTarget
          ]
      where
        csjReasonToJSON = \case
          ChainSync.Client.BecauseCsjDisengage -> String "BecauseCsjDisengage"
          ChainSync.Client.BecauseCsjDisconnect -> String "BecauseCsjDisconnect"


instance HasPrivacyAnnotation (ChainSync.Client.TraceEventDbf peer) where
instance HasSeverityAnnotation (ChainSync.Client.TraceEventDbf peer) where
  getSeverityAnnotation _ = Info
instance ToObject peer
      => Transformable Text IO (ChainSync.Client.TraceEventDbf peer) where
  trTransformer = trStructured
instance HasTextFormatter (ChainSync.Client.TraceEventDbf peer) where
instance ToObject peer
      => ToObject (ChainSync.Client.TraceEventDbf peer) where
    toObject verb = \case
      ChainSync.Client.RotatedDynamo oldPeer newPeer ->
        mconcat
          [ "kind" .= String "RotatedDynamo"
          , "oldPeer" .= toObject verb oldPeer
          , "newPeer" .= toObject verb newPeer
          ]

instance ConvertRawHash blk
      => ToObject (TraceChainSyncServerEvent blk) where
  toObject verb ev = case ev of
    TraceChainSyncServerUpdate tip update blocking enclosing ->
      mconcat $
        [ "kind" .= String "ChainSyncServerEvent.TraceChainSyncServerUpdate"
        , "tip" .= tipToObject tip
        , case update of
            AddBlock pt -> "addBlock" .= renderPointForVerbosity verb pt
            RollBack pt -> "rollBackTo" .= renderPointForVerbosity verb pt
        , "blockingRead" .= case blocking of Blocking -> True; NonBlocking -> False
        ]
        <> [ "risingEdge" .= True | RisingEdge <- [enclosing] ]

instance ( ToObject (ApplyTxErr blk), ToObject (GenTx blk),
           ToJSON (GenTxId blk), LedgerSupportsMempool blk,
           ConvertRawHash blk
         ) => ToObject (TraceEventMempool blk) where
  toObject verb (TraceMempoolAddedTx tx _mpSzBefore mpSzAfter) =
    mconcat
      [ "kind" .= String "TraceMempoolAddedTx"
      , "tx" .= toObject verb (txForgetValidated tx)
      , "mempoolSize" .= toObject verb mpSzAfter
      ]
  toObject verb (TraceMempoolRejectedTx tx txApplyErr mpSz) =
    mconcat $
      [ "kind" .= String "TraceMempoolRejectedTx"
      , "tx" .= toObject verb tx
      , "mempoolSize" .= toObject verb mpSz
      ] <>
      [ "err" .= toObject verb txApplyErr
      | verb == MaximalVerbosity
      ]
  toObject verb (TraceMempoolRemoveTxs txs mpSz) =
    mconcat
      [ "kind" .= String "TraceMempoolRemoveTxs"
      , "txs"
          .= map
            ( \(tx, err) ->
                Aeson.object $
                  [ "tx" .= toObject verb (txForgetValidated tx)
                  ] <>
                  [ "err" .= toObject verb err
                  | verb == MaximalVerbosity
                  ]
            )
            txs
      , "mempoolSize" .= toObject verb mpSz
      ]
  toObject verb (TraceMempoolManuallyRemovedTxs txs0 txs1 mpSz) =
    mconcat
      [ "kind" .= String "TraceMempoolManuallyRemovedTxs"
      , "txsRemoved" .= txs0
      , "txsInvalidated" .= map (toObject verb . txForgetValidated) txs1
      , "mempoolSize" .= toObject verb mpSz
      ]
  toObject _verb (TraceMempoolSynced et) =
    mconcat
      [ "kind" .= String "TraceMempoolSynced"
      , "enclosingTime" .= et
      ]
  toObject verb (TraceMempoolSyncNotNeeded t) =
    mconcat
      [ "kind" .= String "TraceMempoolSyncNotNeeded"
      , "tip" .= toObject verb t
      ]
  toObject verb (TraceMempoolAttemptingAdd tx) =
    mconcat
      [ "kind" .= String "TraceMempoolAttemptingAdd"
      , "tx" .= toObject verb tx
      ]
  toObject verb (TraceMempoolLedgerFound p) =
    mconcat
      [ "kind" .= String "TraceMempoolLedgerFound"
      , "tip" .= toObject verb p
      ]
  toObject verb (TraceMempoolLedgerNotFound p) =
    mconcat
      [ "kind" .= String "TraceMempoolLedgerNotFound"
      , "tip" .= toObject verb p
      ]

instance ToObject MempoolSize where
  toObject _verb MempoolSize{msNumTxs, msNumBytes} =
    mconcat
      [ "numTxs" .= msNumTxs
      , "bytes" .= unByteSize32 msNumBytes
      ]

instance HasTextFormatter () where
  formatText _ = pack . show . toList

-- ForgeStateInfo default value = ()
instance Transformable Text IO () where
  trTransformer = trStructuredText

instance ( RunNode blk
         , ToObject (LedgerError blk)
         , ToObject (OtherHeaderEnvelopeError blk)
         , ToObject (ValidationErr (BlockProtocol blk))
         , ToObject (CannotForge blk)
         , ToObject (ForgeStateUpdateError blk))
      => ToObject (TraceForgeEvent blk) where
  toObject _verb (TraceStartLeadershipCheck slotNo) =
    mconcat
      [ "kind" .= String "TraceStartLeadershipCheck"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject verb (TraceSlotIsImmutable slotNo tipPoint tipBlkNo) =
    mconcat
      [ "kind" .= String "TraceSlotIsImmutable"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "tip" .= renderPointForVerbosity verb tipPoint
      , "tipBlockNo" .= toJSON (unBlockNo tipBlkNo)
      ]
  toObject _verb (TraceBlockFromFuture currentSlot tip) =
    mconcat
      [ "kind" .= String "TraceBlockFromFuture"
      , "current slot" .= toJSON (unSlotNo currentSlot)
      , "tip" .= toJSON (unSlotNo tip)
      ]
  toObject verb (TraceBlockContext currentSlot tipBlkNo tipPoint) =
    mconcat
      [ "kind" .= String "TraceBlockContext"
      , "current slot" .= toJSON (unSlotNo currentSlot)
      , "tip" .= renderPointForVerbosity verb tipPoint
      , "tipBlockNo" .= toJSON (unBlockNo tipBlkNo)
      ]
  toObject _verb (TraceNoLedgerState slotNo _pt) =
    mconcat
      [ "kind" .= String "TraceNoLedgerState"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject _verb (TraceLedgerState slotNo _pt) =
    mconcat
      [ "kind" .= String "TraceLedgerState"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject _verb (TraceNoLedgerView slotNo _) =
    mconcat
      [ "kind" .= String "TraceNoLedgerView"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject _verb (TraceLedgerView slotNo) =
    mconcat
      [ "kind" .= String "TraceLedgerView"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject verb (TraceForgeStateUpdateError slotNo reason) =
    mconcat
      [ "kind" .= String "TraceForgeStateUpdateError"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "reason" .= toObject verb reason
      ]
  toObject verb (TraceNodeCannotForge slotNo reason) =
    mconcat
      [ "kind" .= String "TraceNodeCannotForge"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "reason" .= toObject verb reason
      ]
  toObject _verb (TraceNodeNotLeader slotNo) =
    mconcat
      [ "kind" .= String "TraceNodeNotLeader"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject _verb (TraceNodeIsLeader slotNo) =
    mconcat
      [ "kind" .= String "TraceNodeIsLeader"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject verb (TraceForgeTickedLedgerState slotNo prevPt) =
    mconcat
      [ "kind" .= String "TraceForgeTickedLedgerState"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "prev" .= renderPointForVerbosity verb prevPt
      ]
  toObject verb (TraceForgingMempoolSnapshot slotNo prevPt mpHash mpSlot) =
    mconcat
      [ "kind"        .= String "TraceForgingMempoolSnapshot"
      , "slot"        .= toJSON (unSlotNo slotNo)
      , "prev"        .= renderPointForVerbosity verb prevPt
      , "mempoolHash" .= String (renderChainHash @blk (renderHeaderHash (Proxy @blk)) mpHash)
      , "mempoolSlot" .= toJSON (unSlotNo mpSlot)
      ]
  toObject _verb (TraceForgedBlock slotNo _ blk _) =
    mconcat
      [ "kind"      .= String "TraceForgedBlock"
      , "slot"      .= toJSON (unSlotNo slotNo)
      , "block"     .= String (renderHeaderHash (Proxy @blk) $ blockHash blk)
      , "blockNo"   .= toJSON (unBlockNo $ blockNo blk)
      , "blockPrev" .= String (renderChainHash @blk (renderHeaderHash (Proxy @blk)) $ blockPrevHash blk)
      ]
  toObject _verb (TraceDidntAdoptBlock slotNo _) =
    mconcat
      [ "kind" .= String "TraceDidntAdoptBlock"
      , "slot" .= toJSON (unSlotNo slotNo)
      ]
  toObject verb (TraceForgedInvalidBlock slotNo _ reason) =
    mconcat
      [ "kind" .= String "TraceForgedInvalidBlock"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "reason" .= toObject verb reason
      ]
  toObject MaximalVerbosity (TraceAdoptedBlock slotNo blk txs) =
    mconcat
      [ "kind" .= String "TraceAdoptedBlock"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "blockHash" .= renderHeaderHashForVerbosity
          (Proxy @blk)
          MaximalVerbosity
          (blockHash blk)
      , "blockSize" .= toJSON (getSizeInBytes $ estimateBlockSize (getHeader blk))
      , "txIds" .= toJSON (map (show . txId . txForgetValidated) txs)
      ]
  toObject verb (TraceAdoptedBlock slotNo blk _txs) =
    mconcat
      [ "kind" .= String "TraceAdoptedBlock"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "blockHash" .= renderHeaderHashForVerbosity
          (Proxy @blk)
          verb
          (blockHash blk)
      , "blockSize" .= toJSON (getSizeInBytes $ estimateBlockSize (getHeader blk))
      ]
  toObject verb (TraceAdoptionThreadDied slotNo blk) =
    mconcat
      [ "kind" .= String "TraceAdoptionThreadDied"
      , "slot" .= toJSON (unSlotNo slotNo)
      , "blockHash" .= renderHeaderHashForVerbosity
          (Proxy @blk)
          verb
          (blockHash blk)
      , "blockSize" .= toJSON (getSizeInBytes $ estimateBlockSize (getHeader blk))
      ]


instance ToObject (TraceLocalTxSubmissionServerEvent blk) where
  toObject _verb _ =
    mconcat [ "kind" .= String "TraceLocalTxSubmissionServerEvent" ]

instance HasPrivacyAnnotation (TraceGsmEvent selection) where
instance HasSeverityAnnotation (TraceGsmEvent selection) where
  getSeverityAnnotation _ = Info
instance ToObject selection => Transformable Text IO (TraceGsmEvent selection) where
  trTransformer = trStructured

instance ToObject selection => ToObject (TraceGsmEvent selection) where
  toObject verb (GsmEventEnterCaughtUp i s) =
    mconcat
      [ "kind" .= String "GsmEventEnterCaughtUp"
      , "peerNumber" .= toJSON i
      , "currentSelection" .= toObject verb s
      ]
  toObject verb (GsmEventLeaveCaughtUp s a) =
    mconcat
      [ "kind" .= String "GsmEventLeaveCaughtUp"
      , "currentSelection" .= toObject verb s
      , "age" .= toJSON (show a)
      ]
  toObject _verb GsmEventPreSyncingToSyncing =
    mconcat
      [ "kind" .= String "GsmEventPreSyncingToSyncing"
      ]
  toObject _verb GsmEventSyncingToPreSyncing =
    mconcat
      [ "kind" .= String "GsmEventSyncingToPreSyncing"
      ]

instance HasPrivacyAnnotation (TraceGDDEvent peer blk) where
instance HasSeverityAnnotation (TraceGDDEvent peer blk) where
  getSeverityAnnotation _ = Debug
instance (Typeable blk, ToObject peer, ConvertRawHash blk, GetHeader blk) => Transformable Text IO (TraceGDDEvent peer blk) where
  trTransformer = trStructured

instance (Typeable blk, ToObject peer, ConvertRawHash blk, GetHeader blk) => ToObject (TraceGDDEvent peer blk) where
  toObject verb (TraceGDDDebug (GDDDebugInfo {..})) = mconcat $
    [ "kind" .= String "TraceGDDEvent"
    , "losingPeers".= toJSON (map (toObject verb) losingPeers)
    , "loeHead" .= toObject verb loeHead
    , "sgen" .= toJSON (unGenesisWindow sgen)
    ] <> do
      guard $ verb >= MaximalVerbosity
      [ "bounds" .= toJSON (
           map
           ( \(peer, density) -> Object $ mconcat
             [ "kind" .= String "PeerDensityBound"
             , "peer" .= toObject verb peer
             , "densityBounds" .= toObject verb density
             ]
           )
           bounds
         )
       , "curChain" .= toObject verb curChain
       , "candidates" .= toJSON (
           map
           ( \(peer, frag) -> Object $ mconcat
             [ "kind" .= String "PeerCandidateFragment"
             , "peer" .= toObject verb peer
             , "candidateFragment" .= toObject verb frag
             ]
           )
           candidates
         )
       , "candidateSuffixes" .= toJSON (
           map
           ( \(peer, frag) -> Object $ mconcat
             [ "kind" .= String "PeerCandidateSuffix"
             , "peer" .= toObject verb peer
             , "candidateSuffix" .= toObject verb frag
             ]
           )
           candidateSuffixes
         )
       ]

  toObject verb (TraceGDDDisconnected peer) = mconcat
    [ "kind" .= String "TraceGDDDisconnected"
    , "peer" .= toJSON (map (toObject verb) $ toList peer)
    ]

instance (Typeable blk, ConvertRawHash blk, GetHeader blk) => ToObject (DensityBounds blk) where
  toObject verb DensityBounds {..} = mconcat
    [ "kind" .= String "DensityBounds"
    , "clippedFragment" .= toObject verb clippedFragment
    , "offersMoreThanK" .= toJSON offersMoreThanK
    , "lowerBound" .= toJSON lowerBound
    , "upperBound" .= toJSON upperBound
    , "hasBlockAfter" .= toJSON hasBlockAfter
    , "latestSlot" .= toJSON (unSlotNo <$> withOriginToMaybe latestSlot)
    , "idling" .= toJSON idling
    ]

instance ConvertRawHash blk => ToObject (Tip blk) where
  toObject _verb TipGenesis =
    mconcat [ "kind" .= String "TipGenesis" ]
  toObject _verb (Tip slotNo hash bNo) =
    mconcat [ "kind" .= String "Tip"
            , "tipSlotNo" .= toJSON (unSlotNo slotNo)
            , "tipHash" .= renderHeaderHash (Proxy @blk) hash
            , "tipBlockNo" .= toJSON bNo
            ]
