{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wno-deprecations #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Node.Tracing.Tracers.ChainDB
   ( withAddedToCurrentChainEmptyLimited
   , fragmentChainDensity
   ) where

import           Cardano.Logging
import           Cardano.Node.Tracing.Era.Byron ()
import           Cardano.Node.Tracing.Era.Shelley ()
import           Cardano.Node.Tracing.Formatting ()
import           Cardano.Node.Tracing.Render
import           Cardano.Prelude (maximumDef)
import           Cardano.Tracing.HasIssuer
import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.HeaderValidation (HeaderEnvelopeError (..), HeaderError (..),
                   OtherHeaderEnvelopeError)
import           Ouroboros.Consensus.Ledger.Abstract (LedgerError)
import           Ouroboros.Consensus.Ledger.Extended (ExtValidationError (..))
import           Ouroboros.Consensus.Ledger.Inspect (InspectLedger, LedgerEvent (..))
import           Ouroboros.Consensus.Ledger.SupportsProtocol (LedgerSupportsProtocol)
import           Ouroboros.Consensus.Protocol.Abstract (SelectView, ValidationErr)
import qualified Ouroboros.Consensus.Protocol.PBFT as PBFT
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmDB
import           Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal (chunkNoToInt)
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Types as ImmDB
import qualified Ouroboros.Consensus.Storage.LedgerDB as LedgerDB
import qualified Ouroboros.Consensus.Storage.LedgerDB.Snapshots as LedgerDB
import qualified Ouroboros.Consensus.Storage.LedgerDB.V1.BackingStore as V1
import qualified Ouroboros.Consensus.Storage.LedgerDB.V2.Args as V2
import qualified Ouroboros.Consensus.Storage.VolatileDB as VolDB
import           Ouroboros.Consensus.Util.Condense (condense)
import           Ouroboros.Consensus.Util.Enclose
import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block (MaxSlotNo (..))

import           Data.Aeson (Value (String), object, toJSON, (.=))
import qualified Data.ByteString.Base16 as B16
import           Data.Int (Int64)
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Word (Word64)
import           Numeric (showFFloat)

-- {-# ANN module ("HLint: ignore Redundant bracket" :: Text) #-}

-- A limiter that is not coming from configuration, because it carries a special filter
withAddedToCurrentChainEmptyLimited
  :: Trace IO (ChainDB.TraceEvent blk)
  -> IO (Trace IO (ChainDB.TraceEvent blk))
withAddedToCurrentChainEmptyLimited tr = do
  ltr <- limitFrequency 1.25 "AddedToCurrentChainLimiter" mempty tr
  pure $ routingTrace (selecting ltr) tr
 where
    selecting
      ltr
      (ChainDB.TraceAddBlockEvent (ChainDB.AddedToCurrentChain events _ _ _)) =
        if null events
          then pure ltr
          else pure tr
    selecting _ _ = pure tr


-- --------------------------------------------------------------------------------
-- -- ChainDB Tracer
-- --------------------------------------------------------------------------------

instance (  LogFormatting (Header blk)
          , LogFormatting (LedgerEvent blk)
          , LogFormatting (RealPoint blk)
          , LogFormatting (SelectView (BlockProtocol blk))
          , ConvertRawHash blk
          , ConvertRawHash (Header blk)
          , LedgerSupportsProtocol blk
          , InspectLedger blk
          , HasIssuer blk
          ) => LogFormatting (ChainDB.TraceEvent blk) where
  forHuman ChainDB.TraceLastShutdownUnclean        =
    "ChainDB is not clean. Validating all immutable chunks"
  forHuman (ChainDB.TraceAddBlockEvent v)          = forHumanOrMachine v
  forHuman (ChainDB.TraceFollowerEvent v)          = forHumanOrMachine v
  forHuman (ChainDB.TraceCopyToImmutableDBEvent v) = forHumanOrMachine v
  forHuman (ChainDB.TraceGCEvent v)                = forHumanOrMachine v
  forHuman (ChainDB.TraceInitChainSelEvent v)      = forHumanOrMachine v
  forHuman (ChainDB.TraceOpenEvent v)              = forHumanOrMachine v
  forHuman (ChainDB.TraceIteratorEvent v)          = forHumanOrMachine v
  forHuman (ChainDB.TraceLedgerDBEvent v)          = forHumanOrMachine v
  forHuman (ChainDB.TraceImmutableDBEvent v)       = forHumanOrMachine v
  forHuman (ChainDB.TraceVolatileDBEvent v)        = forHumanOrMachine v
  forHuman (ChainDB.TraceChainSelStarvationEvent ev) = case ev of
        ChainDB.ChainSelStarvation RisingEdge ->
          "Chain Selection was starved."
        ChainDB.ChainSelStarvation (FallingEdgeWith pt) ->
          "Chain Selection was unstarved by " <> renderRealPoint pt

  forMachine _ ChainDB.TraceLastShutdownUnclean =
    mconcat [ "kind" .= String "LastShutdownUnclean" ]
  forMachine dtal (ChainDB.TraceChainSelStarvationEvent (ChainDB.ChainSelStarvation edge)) =
    mconcat [ "kind" .= String "ChainSelStarvation"
             , case edge of
                 RisingEdge -> "risingEdge" .= True
                 FallingEdgeWith pt -> "fallingEdge" .= forMachine dtal pt
             ]
  forMachine details (ChainDB.TraceAddBlockEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceFollowerEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceCopyToImmutableDBEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceGCEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceInitChainSelEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceOpenEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceIteratorEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceLedgerDBEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceImmutableDBEvent v) =
    forMachine details v
  forMachine details (ChainDB.TraceVolatileDBEvent v) =
    forMachine details v

  asMetrics ChainDB.TraceLastShutdownUnclean         = []
  asMetrics (ChainDB.TraceChainSelStarvationEvent _) = []
  asMetrics (ChainDB.TraceAddBlockEvent v)           = asMetrics v
  asMetrics (ChainDB.TraceFollowerEvent v)           = asMetrics v
  asMetrics (ChainDB.TraceCopyToImmutableDBEvent v)  = asMetrics v
  asMetrics (ChainDB.TraceGCEvent v)                 = asMetrics v
  asMetrics (ChainDB.TraceInitChainSelEvent v)       = asMetrics v
  asMetrics (ChainDB.TraceOpenEvent v)               = asMetrics v
  asMetrics (ChainDB.TraceIteratorEvent v)           = asMetrics v
  asMetrics (ChainDB.TraceLedgerDBEvent v)          = asMetrics v
  asMetrics (ChainDB.TraceImmutableDBEvent v)       = asMetrics v
  asMetrics (ChainDB.TraceVolatileDBEvent v)        = asMetrics v


instance MetaTrace  (ChainDB.TraceEvent blk) where
  namespaceFor ChainDB.TraceLastShutdownUnclean =
    Namespace [] ["LastShutdownUnclean"]
  namespaceFor ChainDB.TraceChainSelStarvationEvent{} =
    Namespace [] ["ChainSelStarvationEvent"]
  namespaceFor (ChainDB.TraceAddBlockEvent ev) =
    nsPrependInner "AddBlockEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceFollowerEvent ev) =
    nsPrependInner "FollowerEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceCopyToImmutableDBEvent ev) =
    nsPrependInner "CopyToImmutableDBEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceGCEvent ev) =
    nsPrependInner "GCEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceInitChainSelEvent ev) =
    nsPrependInner "InitChainSelEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceOpenEvent ev) =
    nsPrependInner "OpenEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceIteratorEvent ev) =
    nsPrependInner "IteratorEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceLedgerDBEvent ev) =
    nsPrependInner "LedgerEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceImmutableDBEvent ev) =
    nsPrependInner "ImmDbEvent" (namespaceFor ev)
  namespaceFor (ChainDB.TraceVolatileDBEvent ev) =
     nsPrependInner "VolatileDbEvent" (namespaceFor ev)

  severityFor (Namespace _ ["LastShutdownUnclean"]) _ = Just Info
  severityFor (Namespace _ ["ChainSelStarvationEvent"]) _ = Just Debug
  severityFor (Namespace out ("AddBlockEvent" : tl)) (Just (ChainDB.TraceAddBlockEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("AddBlockEvent" : tl)) Nothing =
    severityFor (Namespace out tl  :: Namespace (ChainDB.TraceAddBlockEvent blk)) Nothing
  severityFor (Namespace out ("FollowerEvent" : tl)) (Just (ChainDB.TraceFollowerEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("FollowerEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TraceFollowerEvent blk)) Nothing
  severityFor (Namespace out ("CopyToImmutableDBEvent" : tl)) (Just (ChainDB.TraceCopyToImmutableDBEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("CopyToImmutableDBEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TraceCopyToImmutableDBEvent blk)) Nothing
  severityFor (Namespace out ("GCEvent" : tl)) (Just (ChainDB.TraceGCEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("GCEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TraceGCEvent blk)) Nothing
  severityFor (Namespace out ("InitChainSelEvent" : tl)) (Just (ChainDB.TraceInitChainSelEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("InitChainSelEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TraceInitChainSelEvent blk)) Nothing
  severityFor (Namespace out ("OpenEvent" : tl)) (Just (ChainDB.TraceOpenEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("OpenEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TraceOpenEvent blk)) Nothing
  severityFor (Namespace out ("IteratorEvent" : tl)) (Just (ChainDB.TraceIteratorEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("IteratorEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TraceIteratorEvent blk)) Nothing
  severityFor (Namespace out ("LedgerEvent" : tl)) (Just (ChainDB.TraceLedgerDBEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("LedgerEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (LedgerDB.TraceEvent blk)) Nothing
  severityFor (Namespace out ("ImmDbEvent" : tl)) (Just (ChainDB.TraceImmutableDBEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("ImmDbEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ImmDB.TraceEvent blk)) Nothing
  severityFor (Namespace out ("VolatileDbEvent" : tl)) (Just (ChainDB.TraceVolatileDBEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("VolatileDbEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (VolDB.TraceEvent blk)) Nothing
  severityFor _ns _ = Nothing

  privacyFor (Namespace _ ["LastShutdownUnclean"]) _ = Just Public
  privacyFor (Namespace _ ["ChainSelStarvationEvent"]) _ = Just Public
  privacyFor (Namespace out ("AddBlockEvent" : tl)) (Just (ChainDB.TraceAddBlockEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("AddBlockEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceAddBlockEvent blk)) Nothing
  privacyFor (Namespace out ("FollowerEvent" : tl)) (Just (ChainDB.TraceFollowerEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("FollowerEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceFollowerEvent blk)) Nothing
  privacyFor (Namespace out ("CopyToImmutableDBEvent" : tl)) (Just (ChainDB.TraceCopyToImmutableDBEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("CopyToImmutableDBEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceCopyToImmutableDBEvent blk)) Nothing
  privacyFor (Namespace out ("GCEvent" : tl)) (Just (ChainDB.TraceGCEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("GCEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceGCEvent blk)) Nothing
  privacyFor (Namespace out ("InitChainSelEvent" : tl)) (Just (ChainDB.TraceInitChainSelEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("InitChainSelEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceInitChainSelEvent blk)) Nothing
  privacyFor (Namespace out ("OpenEvent" : tl)) (Just (ChainDB.TraceOpenEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("OpenEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceOpenEvent blk)) Nothing
  privacyFor (Namespace out ("IteratorEvent" : tl)) (Just (ChainDB.TraceIteratorEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("IteratorEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceIteratorEvent blk)) Nothing
  privacyFor (Namespace out ("LedgerEvent" : tl)) (Just (ChainDB.TraceLedgerDBEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("LedgerEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (LedgerDB.TraceEvent blk)) Nothing
  privacyFor (Namespace out ("ImmDbEvent" : tl)) (Just (ChainDB.TraceImmutableDBEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("ImmDbEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ImmDB.TraceEvent blk)) Nothing
  privacyFor (Namespace out ("VolatileDbEvent" : tl)) (Just (ChainDB.TraceVolatileDBEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("VolatileDbEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (VolDB.TraceEvent blk)) Nothing
  privacyFor _ _ = Nothing

  detailsFor (Namespace _ ["LastShutdownUnclean"]) _ = Just DNormal
  detailsFor (Namespace _ ["ChainSelStarvationEvent"]) _ = Just DNormal
  detailsFor (Namespace out ("AddBlockEvent" : tl)) (Just (ChainDB.TraceAddBlockEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("AddBlockEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceAddBlockEvent blk)) Nothing
  detailsFor (Namespace out ("FollowerEvent" : tl)) (Just (ChainDB.TraceFollowerEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("FollowerEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceFollowerEvent blk)) Nothing
  detailsFor (Namespace out ("CopyToImmutableDBEvent" : tl)) (Just (ChainDB.TraceCopyToImmutableDBEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("CopyToImmutableDBEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceCopyToImmutableDBEvent blk)) Nothing
  detailsFor (Namespace out ("GCEvent" : tl)) (Just (ChainDB.TraceGCEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("GCEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceGCEvent blk)) Nothing
  detailsFor (Namespace out ("InitChainSelEvent" : tl)) (Just (ChainDB.TraceInitChainSelEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("InitChainSelEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceInitChainSelEvent blk)) Nothing
  detailsFor (Namespace out ("OpenEvent" : tl)) (Just (ChainDB.TraceOpenEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("OpenEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceOpenEvent blk)) Nothing
  detailsFor (Namespace out ("IteratorEvent" : tl)) (Just (ChainDB.TraceIteratorEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("IteratorEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceIteratorEvent blk)) Nothing
  detailsFor (Namespace out ("LedgerEvent" : tl)) (Just (ChainDB.TraceLedgerDBEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("LedgerEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (LedgerDB.TraceEvent blk)) Nothing
  detailsFor (Namespace out ("ImmDbEvent" : tl)) (Just (ChainDB.TraceImmutableDBEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("ImmDbEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: (Namespace (ImmDB.TraceEvent blk))) Nothing
  detailsFor (Namespace out ("VolatileDbEvent" : tl)) (Just (ChainDB.TraceVolatileDBEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("VolatileDbEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: (Namespace (VolDB.TraceEvent blk))) Nothing
  detailsFor _ _ = Nothing

  metricsDocFor (Namespace out ("AddBlockEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceAddBlockEvent blk))
  metricsDocFor (Namespace out ("FollowerEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceFollowerEvent blk))
  metricsDocFor (Namespace out ("CopyToImmutableDBEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceCopyToImmutableDBEvent blk))
  metricsDocFor (Namespace out ("GCEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceGCEvent blk))
  metricsDocFor (Namespace out ("InitChainSelEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceInitChainSelEvent blk))
  metricsDocFor (Namespace out ("OpenEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceOpenEvent blk))
  metricsDocFor (Namespace out ("IteratorEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceIteratorEvent blk))
  metricsDocFor (Namespace out ("LedgerEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (LedgerDB.TraceEvent blk))
  metricsDocFor (Namespace out ("ImmDbEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ImmDB.TraceEvent blk))
  metricsDocFor (Namespace out ("VolatileDbEvent" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (VolDB.TraceEvent blk))
  metricsDocFor _ = []

  documentFor (Namespace _ ["LastShutdownUnclean"]) = Just $ mconcat
    [ "Last shutdown of the node didn't leave the ChainDB directory in a clean"
    , " state. Therefore, revalidating all the immutable chunks is necessary to"
    , " ensure the correctness of the chain."
    ]
  documentFor (Namespace _ ["ChainSelStarvationEvent"]) = Just $ mconcat
    [ "ChainSel is waiting for a next block to process, but there is no block in the queue."
    , " Despite the name, it is a pretty normal (and frequent) event."
    ]
  documentFor (Namespace out ("AddBlockEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceAddBlockEvent blk))
  documentFor (Namespace out ("FollowerEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceFollowerEvent blk))
  documentFor (Namespace out ("CopyToImmutableDBEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceCopyToImmutableDBEvent blk))
  documentFor (Namespace out ("GCEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceGCEvent blk))
  documentFor (Namespace out ("InitChainSelEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceInitChainSelEvent blk))
  documentFor (Namespace out ("OpenEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceOpenEvent blk))
  documentFor (Namespace out ("IteratorEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceIteratorEvent blk))
  documentFor (Namespace out ("LedgerEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (LedgerDB.TraceEvent blk))
  documentFor (Namespace out ("ImmDbEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ImmDB.TraceEvent blk))
  documentFor (Namespace out ("VolatileDbEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (VolDB.TraceEvent blk))
  documentFor _ = Nothing

  allNamespaces =
        Namespace [] ["LastShutdownUnclean"]
          : Namespace [] ["ChainSelStarvationEvent"]
          : (map  (nsPrependInner "AddBlockEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceAddBlockEvent blk)])
          ++ map  (nsPrependInner "FollowerEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceFollowerEvent blk)])
          ++ map  (nsPrependInner "CopyToImmutableDBEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceCopyToImmutableDBEvent blk)])
          ++ map  (nsPrependInner "GCEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceGCEvent blk)])
          ++ map  (nsPrependInner "InitChainSelEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceInitChainSelEvent blk)])
          ++ map  (nsPrependInner "OpenEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceOpenEvent blk)])
          ++ map  (nsPrependInner "IteratorEvent")
                  (allNamespaces :: [Namespace (ChainDB.TraceIteratorEvent blk)])
          ++ map  (nsPrependInner "LedgerEvent")
                  (allNamespaces :: [Namespace (LedgerDB.TraceEvent blk)])
          ++ map  (nsPrependInner "ImmDbEvent")
                  (allNamespaces :: [Namespace (ImmDB.TraceEvent blk)])
          ++ map  (nsPrependInner "VolatileDbEvent")
                  (allNamespaces :: [Namespace (VolDB.TraceEvent blk)])
            )


--------------------------------------------------------------------------------
-- AddBlockEvent
--------------------------------------------------------------------------------


instance ( LogFormatting (Header blk)
         , LogFormatting (LedgerEvent blk)
         , LogFormatting (RealPoint blk)
         , LogFormatting (SelectView (BlockProtocol blk))
         , ConvertRawHash blk
         , ConvertRawHash (Header blk)
         , LedgerSupportsProtocol blk
         , InspectLedger blk
         , HasIssuer blk
         ) => LogFormatting (ChainDB.TraceAddBlockEvent blk) where
  forHuman (ChainDB.IgnoreBlockOlderThanK pt) =
    "Ignoring block older than K: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.IgnoreBlockAlreadyInVolatileDB pt) =
      "Ignoring block already in DB: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.IgnoreInvalidBlock pt _reason) =
      "Ignoring previously seen invalid block: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.AddedBlockToQueue pt edgeSz) =
      case edgeSz of
        RisingEdge ->
          "About to add block to queue: " <> renderRealPointAsPhrase pt
        FallingEdgeWith sz ->
          "Block added to queue: " <> renderRealPointAsPhrase pt <> ", queue size " <> condenseT sz
  forHuman (ChainDB.PoppedBlockFromQueue edgePt) =
      case edgePt of
        RisingEdge ->
          "Popping block from queue"
        FallingEdgeWith pt ->
          "Popped block from queue: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.StoreButDontChange pt) =
      "Ignoring block: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.TryAddToCurrentChain pt) =
      "Block fits onto the current chain: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.TrySwitchToAFork pt _) =
      "Block fits onto some fork: " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.ChangingSelection pt) =
      "Changing selection to: " <> renderPointAsPhrase pt
  forHuman (ChainDB.AddedToCurrentChain es _ _ c) =
      "Chain extended, new tip: " <> renderPointAsPhrase (AF.headPoint c) <>
        Text.concat [ "\nEvent: " <> showT e | e <- es ]
  forHuman (ChainDB.SwitchedToAFork es _ _ c) =
      "Switched to a fork, new tip: " <> renderPointAsPhrase (AF.headPoint c) <>
        Text.concat [ "\nEvent: " <> showT e | e <- es ]
  forHuman (ChainDB.AddBlockValidation ev') = forHumanOrMachine ev'
  forHuman (ChainDB.AddedBlockToVolatileDB pt _ _ enclosing) =
      case enclosing of
        RisingEdge  -> "Chain about to add block " <> renderRealPointAsPhrase pt
        FallingEdge -> "Chain added block " <> renderRealPointAsPhrase pt
  forHuman (ChainDB.PipeliningEvent ev') = forHumanOrMachine ev'
  forHuman ChainDB.AddedReprocessLoEBlocksToQueue =
      "Added request to queue to reprocess blocks postponed by LoE."
  forHuman ChainDB.PoppedReprocessLoEBlocksFromQueue =
      "Poppped request from queue to reprocess blocks postponed by LoE."
  forHuman ChainDB.ChainSelectionLoEDebug{} =
      "ChainDB LoE debug event"
  forMachine dtal (ChainDB.IgnoreBlockOlderThanK pt) =
      mconcat [ "kind" .= String "IgnoreBlockOlderThanK"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.IgnoreBlockAlreadyInVolatileDB pt) =
      mconcat [ "kind" .= String "IgnoreBlockAlreadyInVolatileDB"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.IgnoreInvalidBlock pt reason) =
      mconcat [ "kind" .= String "IgnoreInvalidBlock"
               , "block" .= forMachine dtal pt
               , "reason" .= showT reason ]
  forMachine dtal (ChainDB.AddedBlockToQueue pt edgeSz) =
      mconcat [ "kind" .= String "AddedBlockToQueue"
               , "block" .= forMachine dtal pt
               , case edgeSz of
                   RisingEdge         -> "risingEdge" .= True
                   FallingEdgeWith sz -> "queueSize" .= toJSON sz ]
  forMachine dtal (ChainDB.PoppedBlockFromQueue edgePt) =
      mconcat [ "kind" .= String "TraceAddBlockEvent.PoppedBlockFromQueue"
               , case edgePt of
                   RisingEdge         -> "risingEdge" .= True
                   FallingEdgeWith pt -> "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.StoreButDontChange pt) =
      mconcat [ "kind" .= String "StoreButDontChange"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.TryAddToCurrentChain pt) =
      mconcat [ "kind" .= String "TryAddToCurrentChain"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.TrySwitchToAFork pt _) =
      mconcat [ "kind" .= String "TraceAddBlockEvent.TrySwitchToAFork"
               , "block" .= forMachine dtal pt ]
  forMachine dtal (ChainDB.ChangingSelection pt) =
      mconcat [ "kind" .= String "TraceAddBlockEvent.ChangingSelection"
               , "block" .= forMachine dtal pt ]

  forMachine DDetailed (ChainDB.AddedToCurrentChain events selChangedInfo base extended) =
      let ChainInformation { .. } = chainInformation selChangedInfo base extended 0
          tipBlockIssuerVkHashText :: Text
          tipBlockIssuerVkHashText =
            case tipBlockIssuerVerificationKeyHash of
              NoBlockIssuer -> "NoBlockIssuer"
              BlockIssuerVerificationKeyHash bs ->
                Text.decodeLatin1 (B16.encode bs)
      in mconcat $
               [ "kind" .=  String "AddedToCurrentChain"
               , "newtip" .= renderPointForDetails DDetailed (AF.headPoint extended)
               , "newTipSelectView" .= forMachine DDetailed (ChainDB.newTipSelectView selChangedInfo)
               ]
            ++ [ "oldTipSelectView" .= forMachine DDetailed oldTipSelectView
               | Just oldTipSelectView <- [ChainDB.oldTipSelectView selChangedInfo]
               ]
            ++ [ "headers" .= toJSON (forMachine DDetailed `map` addedHdrsNewChain base extended)
               ]
            ++ [ "events" .= toJSON (map (forMachine DDetailed) events)
               | not (null events) ]
            ++ [ "tipBlockHash" .= tipBlockHash
               , "tipBlockParentHash" .= tipBlockParentHash
               , "tipBlockIssuerVKeyHash" .= tipBlockIssuerVkHashText]
  forMachine dtal (ChainDB.AddedToCurrentChain events selChangedInfo _base extended) =
      mconcat $
               [ "kind" .=  String "AddedToCurrentChain"
               , "newtip" .= renderPointForDetails dtal (AF.headPoint extended)
               , "newTipSelectView" .= forMachine dtal (ChainDB.newTipSelectView selChangedInfo)
               ]
            ++ [ "oldTipSelectView" .= forMachine dtal oldTipSelectView
               | Just oldTipSelectView <- [ChainDB.oldTipSelectView selChangedInfo]
               ]
            ++ [ "events" .= toJSON (map (forMachine dtal) events)
               | not (null events) ]

  forMachine DDetailed (ChainDB.SwitchedToAFork events selChangedInfo old new) =
      let ChainInformation { .. } = chainInformation selChangedInfo old new 0
          tipBlockIssuerVkHashText :: Text
          tipBlockIssuerVkHashText =
            case tipBlockIssuerVerificationKeyHash of
              NoBlockIssuer -> "NoBlockIssuer"
              BlockIssuerVerificationKeyHash bs ->
                Text.decodeLatin1 (B16.encode bs)
      in mconcat $
               [ "kind" .= String "TraceAddBlockEvent.SwitchedToAFork"
               , "newtip" .= renderPointForDetails DDetailed (AF.headPoint new)
               , "newTipSelectView" .= forMachine DDetailed (ChainDB.newTipSelectView selChangedInfo)
               ]
            ++ [ "oldTipSelectView" .= forMachine DDetailed oldTipSelectView
               | Just oldTipSelectView <- [ChainDB.oldTipSelectView selChangedInfo]
               ]
            ++ [ "headers" .= toJSON (forMachine DDetailed `map` addedHdrsNewChain old new)
               ]
            ++ [ "events" .= toJSON (map (forMachine DDetailed) events)
               | not (null events) ]
            ++ [ "tipBlockHash" .= tipBlockHash
               , "tipBlockParentHash" .= tipBlockParentHash
               , "tipBlockIssuerVKeyHash" .= tipBlockIssuerVkHashText]
  forMachine dtal (ChainDB.SwitchedToAFork events selChangedInfo _old new) =
      mconcat $
               [ "kind" .= String "TraceAddBlockEvent.SwitchedToAFork"
               , "newtip" .= renderPointForDetails dtal (AF.headPoint new)
               , "newTipSelectView" .= forMachine dtal (ChainDB.newTipSelectView selChangedInfo)
               ]
            ++ [ "oldTipSelectView" .= forMachine dtal oldTipSelectView
               | Just oldTipSelectView <- [ChainDB.oldTipSelectView selChangedInfo]
               ]
            ++ [ "events" .= toJSON (map (forMachine dtal) events)
               | not (null events) ]

  forMachine dtal (ChainDB.AddBlockValidation ev') =
    forMachine dtal ev'
  forMachine dtal (ChainDB.AddedBlockToVolatileDB pt (BlockNo bn) _ enclosing) =
      mconcat $ [ "kind" .= String "AddedBlockToVolatileDB"
                , "block" .= forMachine dtal pt
                , "blockNo" .= showT bn ]
                <> [ "risingEdge" .= True | RisingEdge <- [enclosing] ]
  forMachine dtal (ChainDB.PipeliningEvent ev') =
    forMachine dtal ev'
  forMachine _dtal ChainDB.AddedReprocessLoEBlocksToQueue =
      mconcat [ "kind" .= String "AddedReprocessLoEBlocksToQueue" ]
  forMachine _dtal ChainDB.PoppedReprocessLoEBlocksFromQueue =
      mconcat [ "kind" .= String "PoppedReprocessLoEBlocksFromQueue" ]
  forMachine dtal (ChainDB.ChainSelectionLoEDebug curChain loeFrag) =
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
      headAndAnchor frag = object
        [ "anchor" .= forMachine dtal (AF.anchorPoint frag)
        , "head" .= forMachine dtal (AF.headPoint frag)
        ]


  asMetrics (ChainDB.SwitchedToAFork _warnings selChangedInfo oldChain newChain) =
    let forkIt = not $ AF.withinFragmentBounds (AF.headPoint oldChain)
                              newChain
        ChainInformation { .. } = chainInformation selChangedInfo oldChain newChain 0
        tipBlockIssuerVkHashText =
          case tipBlockIssuerVerificationKeyHash of
            NoBlockIssuer -> "NoBlockIssuer"
            BlockIssuerVerificationKeyHash bs ->
              Text.decodeLatin1 (B16.encode bs)
    in  [ DoubleM "density" (fromRational density)
        , IntM    "slotNum" (fromIntegral slots)
        , IntM    "blockNum" (fromIntegral blocks)
        , IntM    "slotInEpoch" (fromIntegral slotInEpoch)
        , IntM    "epoch" (fromIntegral (unEpochNo epoch))
        , CounterM "forks" (Just (if forkIt then 1 else 0))
        , PrometheusM "tipBlock" [("hash",tipBlockHash)
                                 ,("parent_hash",tipBlockParentHash)
                                 ,("issuer_VKey_hash", tipBlockIssuerVkHashText)]
        ]
  asMetrics (ChainDB.AddedToCurrentChain _warnings selChangedInfo oldChain newChain) =
    let ChainInformation { .. } =
          chainInformation selChangedInfo oldChain newChain 0
        tipBlockIssuerVkHashText =
          case tipBlockIssuerVerificationKeyHash of
            NoBlockIssuer -> "NoBlockIssuer"
            BlockIssuerVerificationKeyHash bs ->
              Text.decodeLatin1 (B16.encode bs)
    in  [ DoubleM "density" (fromRational density)
        , IntM    "slotNum" (fromIntegral slots)
        , IntM    "blockNum" (fromIntegral blocks)
        , IntM    "slotInEpoch" (fromIntegral slotInEpoch)
        , IntM    "epoch" (fromIntegral (unEpochNo epoch))
        , PrometheusM "tipBlock" [("hash",tipBlockHash)
                                 ,("parent_hash",tipBlockParentHash)
                                 ,("issuer_verification_key_hash", tipBlockIssuerVkHashText)]
        ]
  asMetrics _ = []


instance MetaTrace  (ChainDB.TraceAddBlockEvent blk) where
  namespaceFor ChainDB.IgnoreBlockOlderThanK {} =
    Namespace [] ["IgnoreBlockOlderThanK"]
  namespaceFor ChainDB.IgnoreBlockAlreadyInVolatileDB {} =
    Namespace [] ["IgnoreBlockAlreadyInVolatileDB"]
  namespaceFor ChainDB.IgnoreInvalidBlock {} =
    Namespace [] ["IgnoreInvalidBlock"]
  namespaceFor ChainDB.AddedBlockToQueue {} =
    Namespace [] ["AddedBlockToQueue"]
  namespaceFor ChainDB.PoppedBlockFromQueue {} =
    Namespace [] ["PoppedBlockFromQueue"]
  namespaceFor ChainDB.AddedBlockToVolatileDB {} =
    Namespace [] ["AddedBlockToVolatileDB"]
  namespaceFor ChainDB.TryAddToCurrentChain {} =
    Namespace [] ["TryAddToCurrentChain"]
  namespaceFor ChainDB.TrySwitchToAFork {} =
    Namespace [] ["TrySwitchToAFork"]
  namespaceFor ChainDB.StoreButDontChange {} =
    Namespace [] ["StoreButDontChange"]
  namespaceFor ChainDB.AddedToCurrentChain {} =
    Namespace [] ["AddedToCurrentChain"]
  namespaceFor ChainDB.SwitchedToAFork {} =
    Namespace [] ["SwitchedToAFork"]
  namespaceFor ChainDB.ChangingSelection {} =
    Namespace [] ["ChangingSelection"]
  namespaceFor (ChainDB.AddBlockValidation ev') =
    nsPrependInner "AddBlockValidation" (namespaceFor ev')
  namespaceFor (ChainDB.PipeliningEvent ev') =
    nsPrependInner "PipeliningEvent" (namespaceFor ev')
  namespaceFor ChainDB.AddedReprocessLoEBlocksToQueue =
    Namespace [] ["AddedReprocessLoEBlocksToQueue"]
  namespaceFor ChainDB.PoppedReprocessLoEBlocksFromQueue =
    Namespace [] ["PoppedReprocessLoEBlocksFromQueue"]
  namespaceFor ChainDB.ChainSelectionLoEDebug {} =
    Namespace [] ["ChainSelectionLoEDebug"]

  severityFor (Namespace _ ["IgnoreBlockOlderThanK"]) _ = Just Info
  severityFor (Namespace _ ["IgnoreBlockAlreadyInVolatileDB"]) _ = Just Info
  severityFor (Namespace _ ["IgnoreInvalidBlock"]) _ = Just Info
  severityFor (Namespace _ ["AddedBlockToQueue"]) _ = Just Debug
  severityFor (Namespace _ ["AddedBlockToVolatileDB"]) _ = Just Debug
  severityFor (Namespace _ ["PoppedBlockFromQueue"]) _ = Just Debug
  severityFor (Namespace _ ["TryAddToCurrentChain"]) _ = Just Debug
  severityFor (Namespace _ ["TrySwitchToAFork"]) _ = Just Info
  severityFor (Namespace _ ["StoreButDontChange"]) _ = Just Debug
  severityFor (Namespace _ ["ChangingSelection"]) _ = Just Debug
  severityFor (Namespace _ ["AddedToCurrentChain"])
              (Just (ChainDB.AddedToCurrentChain events _ _ _)) =
    Just $ maximumDef Notice (map sevLedgerEvent events)
  severityFor (Namespace _ ["AddedToCurrentChain"]) Nothing = Just Notice
  severityFor (Namespace _ ["SwitchedToAFork"])
              (Just (ChainDB.SwitchedToAFork events _ _ _)) =
    Just $ maximumDef Notice (map sevLedgerEvent events)
  severityFor (Namespace _ ["SwitchedToAFork"]) _ =
    Just Notice
  severityFor (Namespace out ("AddBlockValidation" : tl))
              (Just (ChainDB.AddBlockValidation ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace _ ("AddBlockValidation" : _tl)) Nothing = Just Notice
  severityFor (Namespace out ("PipeliningEvent" : tl)) (Just (ChainDB.PipeliningEvent ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("PipeliningEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (ChainDB.TracePipeliningEvent blk)) Nothing
  severityFor (Namespace _ ["AddedReprocessLoEBlocksToQueue"]) _ = Just Debug
  severityFor (Namespace _ ["PoppedReprocessLoEBlocksFromQueue"]) _ = Just Debug
  severityFor (Namespace _ ["ChainSelectionLoEDebug"]) _ = Just Debug
  severityFor _ _ = Nothing

  privacyFor (Namespace out ("AddBlockEvent" : tl)) (Just (ChainDB.AddBlockValidation ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("AddBlockEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TraceValidationEvent blk)) Nothing
  privacyFor (Namespace out ("PipeliningEvent" : tl)) (Just (ChainDB.PipeliningEvent ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("PipeliningEvent" : tl)) Nothing =
    privacyFor (Namespace out tl :: Namespace (ChainDB.TracePipeliningEvent blk)) Nothing
  privacyFor _ _ = Just Public

  detailsFor (Namespace out ("AddBlockEvent" : tl)) (Just (ChainDB.AddBlockValidation ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("AddBlockEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TraceValidationEvent blk)) Nothing
  detailsFor (Namespace out ("PipeliningEvent" : tl)) (Just (ChainDB.PipeliningEvent ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("PipeliningEvent" : tl)) Nothing =
    detailsFor (Namespace out tl :: Namespace (ChainDB.TracePipeliningEvent blk)) Nothing
  detailsFor _ _ = Just DNormal

  metricsDocFor (Namespace _ ["SwitchedToAFork"]) =
        [ ( "density"
          , mconcat
            [ "The actual number of blocks created over the maximum expected number"
            , " of blocks that could be created over the span of the last @k@ blocks."
            ]
          )
        , ( "slotNum"
          , "Number of slots in this chain fragment."
          )
        , ( "blockNum"
          , "Number of blocks in this chain fragment."
          )
        , ( "slotInEpoch"
          , mconcat
            [ "Relative slot number of the tip of the current chain within the"
            , " epoch.."
            ]
          )
        , ( "epoch"
          , "In which epoch is the tip of the current chain."
          )
        , ( "forks"
          , "counter for forks"
          )
        , ( "tipBlock"
          , "Values for hash, parent hash and issuer verification key hash"
          )
        ]

  metricsDocFor (Namespace _ ["AddedToCurrentChain"]) =
        [ ( "density"
          , mconcat
            [ "The actual number of blocks created over the maximum expected number"
            , " of blocks that could be created over the span of the last @k@ blocks."
            ]
          )
        , ( "slotNum"
          , "Number of slots in this chain fragment."
          )
        , ( "blockNum"
          , "Number of blocks in this chain fragment."
          )
        , ( "slotInEpoch"
          , mconcat
            [ "Relative slot number of the tip of the current chain within the"
            , " epoch.."
            ]
          )
        , ( "epoch"
          , "In which epoch is the tip of the current chain."
          )
        , ( "tipBlock"
          , "Values for hash, parent hash and issuer verification key hash"
          )
        ]
  metricsDocFor _ = []

  documentFor (Namespace _ ["IgnoreBlockOlderThanK"]) = Just $ mconcat
    [ "A block with a 'BlockNo' more than @k@ back than the current tip"
    , " was ignored."
    ]
  documentFor (Namespace _ ["IgnoreBlockAlreadyInVolatileDB"]) = Just
    "A block that is already in the Volatile DB was ignored."
  documentFor (Namespace _ ["IgnoreInvalidBlock"]) = Just
    "A block that is invalid was ignored."
  documentFor (Namespace _ ["AddedBlockToQueue"]) = Just $ mconcat
    [ "The block was added to the queue and will be added to the ChainDB by"
    , " the background thread. The size of the queue is included.."
    ]
  documentFor (Namespace _ ["AddedBlockToVolatileDB"]) = Just
    "A block was added to the Volatile DB"
  documentFor (Namespace _ ["PoppedBlockFromQueue"]) = Just ""
  documentFor (Namespace _ ["TryAddToCurrentChain"]) = Just $ mconcat
    [ "The block fits onto the current chain, we'll try to use it to extend"
    , " our chain."
    ]
  documentFor (Namespace _ ["TrySwitchToAFork"]) = Just $ mconcat
    [ "The block fits onto some fork, we'll try to switch to that fork (if"
    , " it is preferable to our chain)"
    ]
  documentFor (Namespace _ ["StoreButDontChange"]) = Just $ mconcat
    [ "The block fits onto some fork, we'll try to switch to that fork (if"
    , " it is preferable to our chain)."
    ]
  documentFor (Namespace _ ["ChangingSelection"]) = Just $ mconcat
    [ "The new block fits onto the current chain (first"
    , " fragment) and we have successfully used it to extend our (new) current"
    , " chain (second fragment)."
    ]
  documentFor (Namespace _ ["AddedToCurrentChain"]) = Just $ mconcat
    [ "The new block fits onto the current chain (first"
    , " fragment) and we have successfully used it to extend our (new) current"
    , " chain (second fragment)."
    ]
  documentFor (Namespace _out ["SwitchedToAFork"]) = Just $ mconcat
    [ "The new block fits onto some fork and we have switched to that fork"
    , " (second fragment), as it is preferable to our (previous) current chain"
    , " (first fragment)."
    ]
  documentFor (Namespace out ("AddBlockValidation" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TraceValidationEvent blk))
  documentFor (Namespace out ("PipeliningEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace (ChainDB.TracePipeliningEvent blk))
  documentFor _ = Nothing


  allNamespaces =
    [ Namespace [] ["IgnoreBlockOlderThanK"]
    , Namespace [] ["IgnoreBlockAlreadyInVolatileDB"]
    , Namespace [] ["IgnoreInvalidBlock"]
    , Namespace [] ["AddedBlockToQueue"]
    , Namespace [] ["AddedBlockToVolatileDB"]
    , Namespace [] ["PoppedBlockFromQueue"]
    , Namespace [] ["TryAddToCurrentChain"]
    , Namespace [] ["TrySwitchToAFork"]
    , Namespace [] ["StoreButDontChange"]
    , Namespace [] ["ChangingSelection"]
    , Namespace [] ["AddedToCurrentChain"]
    , Namespace [] ["SwitchedToAFork"]
    , Namespace [] ["AddedReprocessLoEBlocksToQueue"]
    , Namespace [] ["PoppedReprocessLoEBlocksFromQueue"]
    , Namespace [] ["ChainSelectionLoEDebug"]
    ]
    ++ map (nsPrependInner "PipeliningEvent")
          (allNamespaces :: [Namespace (ChainDB.TracePipeliningEvent blk)])
    ++ map (nsPrependInner "AddBlockValidation")
          (allNamespaces :: [Namespace (ChainDB.TraceValidationEvent blk)])

--------------------------------------------------------------------------------
-- ChainDB TracePipeliningEvent
--------------------------------------------------------------------------------

instance ( ConvertRawHash (Header blk)
         , HasHeader (Header blk)
         ) => LogFormatting (ChainDB.TracePipeliningEvent blk) where
  forHuman (ChainDB.SetTentativeHeader hdr enclosing) =
      case enclosing of
        RisingEdge  -> "About to set tentative header to " <> renderPointAsPhrase (blockPoint hdr)
        FallingEdge -> "Set tentative header to " <> renderPointAsPhrase (blockPoint hdr)
  forHuman (ChainDB.TrapTentativeHeader hdr) =
      "Discovered trap tentative header " <> renderPointAsPhrase (blockPoint hdr)
  forHuman (ChainDB.OutdatedTentativeHeader hdr) =
      "Tentative header is now outdated " <> renderPointAsPhrase (blockPoint hdr)

  forMachine dtals (ChainDB.SetTentativeHeader hdr enclosing) =
      mconcat $ [ "kind" .= String "SetTentativeHeader"
                , "block" .= renderPointForDetails dtals (blockPoint hdr) ]
                <> [ "risingEdge" .= True | RisingEdge <- [enclosing] ]
  forMachine dtals (ChainDB.TrapTentativeHeader hdr) =
      mconcat [ "kind" .= String "TrapTentativeHeader"
               , "block" .= renderPointForDetails dtals (blockPoint hdr) ]
  forMachine dtals (ChainDB.OutdatedTentativeHeader hdr) =
      mconcat [ "kind" .= String "OutdatedTentativeHeader"
               , "block" .= renderPointForDetails dtals (blockPoint hdr)]

instance MetaTrace  (ChainDB.TracePipeliningEvent blk) where
  namespaceFor ChainDB.SetTentativeHeader {} =
    Namespace [] ["SetTentativeHeader"]
  namespaceFor ChainDB.TrapTentativeHeader {} =
    Namespace [] ["TrapTentativeHeader"]
  namespaceFor ChainDB.OutdatedTentativeHeader {} =
    Namespace [] ["OutdatedTentativeHeader"]

  severityFor (Namespace _ ["SetTentativeHeader"]) _ = Just Debug
  severityFor (Namespace _ ["TrapTentativeHeader"]) _ = Just Debug
  severityFor (Namespace _ ["OutdatedTentativeHeader"]) _ = Just Debug
  severityFor _ _ = Nothing

  documentFor (Namespace _ ["SetTentativeHeader"]) = Just
    "A new tentative header got set"
  documentFor (Namespace _ ["TrapTentativeHeader"]) = Just
    "The body of tentative block turned out to be invalid."
  documentFor (Namespace _ ["OutdatedTentativeHeader"]) = Just
    "We selected a new (better) chain, which cleared the previous tentative header."
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["SetTentativeHeader"]
    , Namespace [] ["TrapTentativeHeader"]
    , Namespace [] ["OutdatedTentativeHeader"]
    ]


addedHdrsNewChain :: HasHeader (Header blk)
  => AF.AnchoredFragment (Header blk)
  -> AF.AnchoredFragment (Header blk)
  -> [Header blk]
addedHdrsNewChain fro to_ =
 case AF.intersect fro to_ of
   Just (_, _, _, s2 :: AF.AnchoredFragment (Header blk)) ->
     AF.toOldestFirst s2
   Nothing -> [] -- No sense to do validation here.

--------------------------------------------------------------------------------
-- ChainDB TraceFollowerEvent
--------------------------------------------------------------------------------

instance (ConvertRawHash blk, StandardHash blk) =>
            LogFormatting (ChainDB.TraceFollowerEvent blk) where
  forHuman ChainDB.NewFollower = "A new Follower was created"
  forHuman (ChainDB.FollowerNoLongerInMem _rrs) = mconcat
    [ "The follower was in the 'FollowerInMem' state but its point is no longer on"
    , " the in-memory chain fragment, so it has to switch to the"
    , " 'FollowerInImmutableDB' state"
    ]
  forHuman (ChainDB.FollowerSwitchToMem point slot) = mconcat
    [ "The follower was in the 'FollowerInImmutableDB' state and is switched to"
    , " the 'FollowerInMem' state. Point: " <> showT point <> " slot: " <> showT slot
    ]
  forHuman (ChainDB.FollowerNewImmIterator point slot) = mconcat
    [ "The follower is in the 'FollowerInImmutableDB' state but the iterator is"
    , " exhausted while the ImmDB has grown, so we open a new iterator to"
    , " stream these blocks too. Point: " <> showT point <> " slot: " <> showT slot
    ]

  forMachine _dtal ChainDB.NewFollower =
      mconcat [ "kind" .= String "NewFollower" ]
  forMachine _dtal (ChainDB.FollowerNoLongerInMem _) =
      mconcat [ "kind" .= String "FollowerNoLongerInMem" ]
  forMachine _dtal (ChainDB.FollowerSwitchToMem _ _) =
      mconcat [ "kind" .= String "FollowerSwitchToMem" ]
  forMachine _dtal (ChainDB.FollowerNewImmIterator _ _) =
      mconcat [ "kind" .= String "FollowerNewImmIterator" ]

instance MetaTrace (ChainDB.TraceFollowerEvent blk) where
  namespaceFor ChainDB.NewFollower =
    Namespace [] ["NewFollower"]
  namespaceFor ChainDB.FollowerNoLongerInMem {} =
    Namespace [] ["FollowerNoLongerInMem"]
  namespaceFor ChainDB.FollowerSwitchToMem {} =
    Namespace [] ["FollowerSwitchToMem"]
  namespaceFor ChainDB.FollowerNewImmIterator {} =
    Namespace [] ["FollowerNewImmIterator"]

  severityFor (Namespace _ ["NewFollower"]) _ = Just Debug
  severityFor (Namespace _ ["FollowerNoLongerInMem"]) _ = Just Debug
  severityFor (Namespace _ ["FollowerSwitchToMem"]) _ = Just Debug
  severityFor (Namespace _ ["FollowerNewImmIterator"]) _ = Just Debug
  severityFor _ _ = Nothing

  documentFor (Namespace _ ["NewFollower"]) = Just
    "A new follower was created."
  documentFor (Namespace _ ["FollowerNoLongerInMem"]) = Just $ mconcat
    [ "The follower was in 'FollowerInMem' state and is switched to"
    , " the 'FollowerInImmutableDB' state."
    ]
  documentFor (Namespace _ ["FollowerSwitchToMem"]) = Just $ mconcat
    [ "The follower was in the 'FollowerInImmutableDB' state and is switched to"
    , " the 'FollowerInMem' state."
    ]
  documentFor (Namespace _ ["FollowerNewImmIterator"]) = Just $ mconcat
    [ "The follower is in the 'FollowerInImmutableDB' state but the iterator is"
    , " exhausted while the ImmDB has grown, so we open a new iterator to"
    , " stream these blocks too."
    ]
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["NewFollower"]
    , Namespace [] ["FollowerNoLongerInMem"]
    , Namespace [] ["FollowerSwitchToMem"]
    , Namespace [] ["FollowerNewImmIterator"]
    ]


--------------------------------------------------------------------------------
-- ChainDB TraceCopyToImmutableDB
--------------------------------------------------------------------------------

instance ConvertRawHash blk
          => LogFormatting (ChainDB.TraceCopyToImmutableDBEvent blk) where
  forHuman (ChainDB.CopiedBlockToImmutableDB pt) =
      "Copied block " <> renderPointAsPhrase pt <> " to the ImmDB"
  forHuman ChainDB.NoBlocksToCopyToImmutableDB  =
      "There are no blocks to copy to the ImmDB"

  forMachine dtals (ChainDB.CopiedBlockToImmutableDB pt) =
      mconcat [ "kind" .= String "CopiedBlockToImmutableDB"
               , "slot" .= forMachine dtals pt ]
  forMachine _dtals ChainDB.NoBlocksToCopyToImmutableDB =
      mconcat [ "kind" .= String "NoBlocksToCopyToImmutableDB" ]

instance MetaTrace (ChainDB.TraceCopyToImmutableDBEvent blk) where
  namespaceFor ChainDB.CopiedBlockToImmutableDB {} =
    Namespace [] ["CopiedBlockToImmutableDB"]
  namespaceFor ChainDB.NoBlocksToCopyToImmutableDB {} =
    Namespace [] ["NoBlocksToCopyToImmutableDB"]

  severityFor (Namespace _ ["CopiedBlockToImmutableDB"]) _ = Just Debug
  severityFor (Namespace _ ["NoBlocksToCopyToImmutableDB"]) _ = Just Debug
  severityFor _ _ = Nothing

  documentFor (Namespace _ ["CopiedBlockToImmutableDB"]) = Just
    "A block was successfully copied to the ImmDB."
  documentFor (Namespace _ ["NoBlocksToCopyToImmutableDB"]) = Just
     "There are no block to copy to the ImmDB."
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["CopiedBlockToImmutableDB"]
    , Namespace [] ["NoBlocksToCopyToImmutableDB"]
    ]

-- --------------------------------------------------------------------------------
-- -- ChainDB GCEvent
-- --------------------------------------------------------------------------------

instance LogFormatting (ChainDB.TraceGCEvent blk) where
  forHuman (ChainDB.PerformedGC slot) =
      "Performed a garbage collection for " <> condenseT slot
  forHuman (ChainDB.ScheduledGC slot _difft) =
      "Scheduled a garbage collection for " <> condenseT slot

  forMachine dtals (ChainDB.PerformedGC slot) =
      mconcat [ "kind" .= String "PerformedGC"
               , "slot" .= forMachine dtals slot ]
  forMachine dtals (ChainDB.ScheduledGC slot difft) =
      mconcat $ [ "kind" .= String "ScheduledGC"
                 , "slot" .= forMachine dtals slot ] <>
                 [ "difft" .= String ((Text.pack . show) difft) | dtals >= DDetailed]

instance MetaTrace (ChainDB.TraceGCEvent blk) where
  namespaceFor ChainDB.PerformedGC {} =
    Namespace [] ["PerformedGC"]
  namespaceFor ChainDB.ScheduledGC {} =
    Namespace [] ["ScheduledGC"]

  severityFor (Namespace _ ["PerformedGC"]) _ = Just Debug
  severityFor (Namespace _ ["ScheduledGC"]) _ = Just Debug
  severityFor _ _ = Nothing

  documentFor (Namespace _ ["PerformedGC"]) = Just
    "A garbage collection for the given 'SlotNo' was performed."
  documentFor (Namespace _ ["ScheduledGC"]) = Just $ mconcat
     [ "A garbage collection for the given 'SlotNo' was scheduled to happen"
     , " at the given time."
     ]
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["PerformedGC"]
    , Namespace [] ["ScheduledGC"]
    ]

-- --------------------------------------------------------------------------------
-- -- TraceInitChainSelEvent
-- --------------------------------------------------------------------------------

instance (ConvertRawHash blk, LedgerSupportsProtocol blk)
  => LogFormatting (ChainDB.TraceInitChainSelEvent blk) where
    forHuman (ChainDB.InitChainSelValidation v) = forHumanOrMachine v
    forHuman ChainDB.InitialChainSelected{} =
        "Initial chain selected"
    forHuman ChainDB.StartedInitChainSelection {} =
        "Started initial chain selection"

    forMachine dtal (ChainDB.InitChainSelValidation v) = forMachine dtal v
    forMachine _dtal ChainDB.InitialChainSelected =
      mconcat ["kind" .= String "Follower.InitialChainSelected"]
    forMachine _dtal ChainDB.StartedInitChainSelection =
      mconcat ["kind" .= String "Follower.StartedInitChainSelection"]

    asMetrics (ChainDB.InitChainSelValidation v) = asMetrics v
    asMetrics ChainDB.InitialChainSelected        = []
    asMetrics ChainDB.StartedInitChainSelection  = []

instance MetaTrace (ChainDB.TraceInitChainSelEvent blk) where
  namespaceFor ChainDB.InitialChainSelected {} =
    Namespace [] ["InitialChainSelected"]
  namespaceFor ChainDB.StartedInitChainSelection {} =
    Namespace [] ["StartedInitChainSelection"]
  namespaceFor (ChainDB.InitChainSelValidation ev') =
    nsPrependInner "Validation" (namespaceFor ev')

  severityFor (Namespace _ ["InitialChainSelected"]) _ = Just Info
  severityFor (Namespace _ ["StartedInitChainSelection"]) _ = Just Info
  severityFor (Namespace out ("Validation" : tl))
                            (Just (ChainDB.InitChainSelValidation ev')) =
    severityFor (Namespace out tl) (Just ev')
  severityFor (Namespace out ("Validation" : tl)) Nothing =
    severityFor (Namespace out tl ::
      Namespace (ChainDB.TraceValidationEvent blk)) Nothing
  severityFor _ _ = Nothing

  privacyFor (Namespace out ("Validation" : tl))
              (Just (ChainDB.InitChainSelValidation ev')) =
    privacyFor (Namespace out tl) (Just ev')
  privacyFor (Namespace out ("Validation" : tl)) Nothing =
    privacyFor (Namespace out tl ::
      Namespace (ChainDB.TraceValidationEvent blk)) Nothing
  privacyFor _ _ = Just Public

  detailsFor (Namespace out ("Validation" : tl))
              (Just (ChainDB.InitChainSelValidation ev')) =
    detailsFor (Namespace out tl) (Just ev')
  detailsFor (Namespace out ("Validation" : tl)) Nothing =
    detailsFor (Namespace out tl ::
      Namespace (ChainDB.TraceValidationEvent blk)) Nothing
  detailsFor _ _ = Just DNormal

  metricsDocFor (Namespace out ("Validation" : tl)) =
    metricsDocFor (Namespace out tl :: Namespace (ChainDB.TraceValidationEvent blk))
  metricsDocFor _ = []

  documentFor (Namespace _ ["InitialChainSelected"]) = Just
    "A garbage collection for the given 'SlotNo' was performed."
  documentFor (Namespace _ ["StartedInitChainSelection"]) = Just $ mconcat
    [ "A garbage collection for the given 'SlotNo' was scheduled to happen"
    , " at the given time."
    ]
  documentFor (Namespace o ("Validation" : tl)) =
     documentFor (Namespace o tl :: Namespace (ChainDB.TraceValidationEvent blk))
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["InitialChainSelected"]
    , Namespace [] ["StartedInitChainSelection"]
    ]
    ++ map (nsPrependInner "Validation")
          (allNamespaces :: [Namespace (ChainDB.TraceValidationEvent blk)])



--------------------------------------------------------------------------------
-- ChainDB TraceValidationEvent
--------------------------------------------------------------------------------

instance ( LedgerSupportsProtocol blk
         , ConvertRawHash (Header blk)
         , ConvertRawHash blk
         , LogFormatting (RealPoint blk))
         => LogFormatting (ChainDB.TraceValidationEvent blk) where
    forHuman (ChainDB.InvalidBlock err pt) =
        "Invalid block " <> renderRealPointAsPhrase pt <> ": " <> showT err
    forHuman (ChainDB.ValidCandidate c) =
        "Valid candidate " <> renderPointAsPhrase (AF.headPoint c)
    forHuman (ChainDB.UpdateLedgerDbTraceEvent
                (LedgerDB.StartedPushingBlockToTheLedgerDb
                  (LedgerDB.PushStart start)
                  (LedgerDB.PushGoal goal)
                  (LedgerDB.Pushing curr))) =
            let fromSlot = unSlotNo $ realPointSlot start
                atSlot   = unSlotNo $ realPointSlot curr
                atDiff   = atSlot - fromSlot
                toSlot   = unSlotNo $ realPointSlot goal
                toDiff   = toSlot - fromSlot
            in
              "Pushing ledger state for block " <> renderRealPointAsPhrase curr <> ". Progress: " <>
              showProgressT (fromIntegral atDiff) (fromIntegral toDiff) <> "%"

    forMachine dtal  (ChainDB.InvalidBlock err pt) =
            mconcat [ "kind" .= String "InvalidBlock"
                     , "block" .= forMachine dtal pt
                     , "error" .= showT err ]
    forMachine dtal  (ChainDB.ValidCandidate c) =
            mconcat [ "kind" .= String "ValidCandidate"
                     , "block" .= renderPointForDetails dtal (AF.headPoint c) ]
    forMachine _dtal (ChainDB.UpdateLedgerDbTraceEvent
                        (LedgerDB.StartedPushingBlockToTheLedgerDb
                          (LedgerDB.PushStart start)
                          (LedgerDB.PushGoal goal)
                          (LedgerDB.Pushing curr))) =
            mconcat [ "kind" .= String "UpdateLedgerDbTraceEvent.StartedPushingBlockToTheLedgerDb"
                     , "startingBlock" .= renderRealPoint start
                     , "currentBlock" .= renderRealPoint curr
                     , "targetBlock" .= renderRealPoint goal
                     ]

instance MetaTrace (ChainDB.TraceValidationEvent blk) where
    namespaceFor ChainDB.ValidCandidate {} =
      Namespace [] ["ValidCandidate"]
    namespaceFor ChainDB.InvalidBlock {} =
      Namespace [] ["InvalidBlock"]
    namespaceFor ChainDB.UpdateLedgerDbTraceEvent {} =
      Namespace [] ["UpdateLedgerDb"]

    severityFor (Namespace _ ["ValidCandidate"]) _ = Just Info
    severityFor (Namespace _ ["InvalidBlock"]) _ = Just Error
    severityFor (Namespace _ ["UpdateLedgerDb"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["ValidCandidate"]) = Just $ mconcat
        [ "An event traced during validating performed while adding a block."
        , " A candidate chain was valid."
        ]
    documentFor (Namespace _ ["InvalidBlock"]) = Just $ mconcat
        [ "An event traced during validating performed while adding a block."
        , " A point was found to be invalid."
        ]
    documentFor (Namespace _ ["UpdateLedgerDb"]) = Just ""
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["ValidCandidate"]
      , Namespace [] ["InvalidBlock"]
      , Namespace [] ["UpdateLedgerDb"]
      ]

--------------------------------------------------------------------------------
-- TraceOpenEvent
--------------------------------------------------------------------------------

instance ConvertRawHash blk
          => LogFormatting (ChainDB.TraceOpenEvent blk) where
  forHuman (ChainDB.OpenedDB immTip tip') =
          "Opened db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and tip " <> renderPointAsPhrase tip'
  forHuman (ChainDB.ClosedDB immTip tip') =
          "Closed db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and tip " <> renderPointAsPhrase tip'
  forHuman (ChainDB.OpenedImmutableDB immTip chunk) =
          "Opened imm db with immutable tip at " <> renderPointAsPhrase immTip <>
          " and chunk " <> showT chunk
  forHuman (ChainDB.OpenedVolatileDB mx) = "Opened " <> case mx of
          NoMaxSlotNo -> "empty Volatile DB"
          MaxSlotNo mxx -> "Volatile DB with max slot seen " <> showT mxx
  forHuman ChainDB.OpenedLgrDB = "Opened lgr db"
  forHuman ChainDB.StartedOpeningDB = "Started opening Chain DB"
  forHuman ChainDB.StartedOpeningImmutableDB = "Started opening Immutable DB"
  forHuman ChainDB.StartedOpeningVolatileDB = "Started opening Volatile DB"
  forHuman ChainDB.StartedOpeningLgrDB = "Started opening Ledger DB"

  forMachine dtal (ChainDB.OpenedDB immTip tip')=
    mconcat [ "kind" .= String "OpenedDB"
             , "immtip" .= forMachine dtal immTip
             , "tip" .= forMachine dtal tip' ]
  forMachine dtal (ChainDB.ClosedDB immTip tip') =
    mconcat [ "kind" .= String "TraceOpenEvent.ClosedDB"
             , "immtip" .= forMachine dtal immTip
             , "tip" .= forMachine dtal tip' ]
  forMachine dtal (ChainDB.OpenedImmutableDB immTip epoch) =
    mconcat [ "kind" .= String "OpenedImmutableDB"
             , "immtip" .= forMachine dtal immTip
             , "epoch" .= String ((Text.pack . show) epoch) ]
  forMachine _dtal (ChainDB.OpenedVolatileDB maxSlotN) =
      mconcat [ "kind" .= String "OpenedVolatileDB"
               , "maxSlotNo" .= String (showT maxSlotN) ]
  forMachine _dtal ChainDB.OpenedLgrDB =
      mconcat [ "kind" .= String "OpenedLgrDB" ]
  forMachine _dtal ChainDB.StartedOpeningDB =
      mconcat ["kind" .= String "StartedOpeningDB"]
  forMachine _dtal ChainDB.StartedOpeningImmutableDB =
      mconcat ["kind" .= String "StartedOpeningImmutableDB"]
  forMachine _dtal ChainDB.StartedOpeningVolatileDB =
      mconcat ["kind" .= String "StartedOpeningVolatileDB"]
  forMachine _dtal ChainDB.StartedOpeningLgrDB =
      mconcat ["kind" .= String "StartedOpeningLgrDB"]

instance MetaTrace (ChainDB.TraceOpenEvent blk) where
    namespaceFor ChainDB.OpenedDB {} =
      Namespace [] ["OpenedDB"]
    namespaceFor ChainDB.ClosedDB {} =
      Namespace [] ["ClosedDB"]
    namespaceFor ChainDB.OpenedImmutableDB {} =
      Namespace [] ["OpenedImmutableDB"]
    namespaceFor ChainDB.OpenedVolatileDB {} =
      Namespace [] ["OpenedVolatileDB"]
    namespaceFor ChainDB.OpenedLgrDB {} =
      Namespace [] ["OpenedLgrDB"]
    namespaceFor ChainDB.StartedOpeningDB {} =
      Namespace [] ["StartedOpeningDB"]
    namespaceFor ChainDB.StartedOpeningImmutableDB {} =
      Namespace [] ["StartedOpeningImmutableDB"]
    namespaceFor ChainDB.StartedOpeningVolatileDB {} =
      Namespace [] ["StartedOpeningVolatileDB"]
    namespaceFor ChainDB.StartedOpeningLgrDB {} =
      Namespace [] ["StartedOpeningLgrDB"]

    severityFor (Namespace _ ["OpenedDB"]) _ = Just Info
    severityFor (Namespace _ ["ClosedDB"]) _ = Just Info
    severityFor (Namespace _ ["OpenedImmutableDB"]) _ = Just Info
    severityFor (Namespace _ ["OpenedVolatileDB"]) _ = Just Info
    severityFor (Namespace _ ["OpenedLgrDB"]) _ = Just Info
    severityFor (Namespace _ ["StartedOpeningDB"]) _ = Just Info
    severityFor (Namespace _ ["StartedOpeningImmutableDB"]) _ = Just Info
    severityFor (Namespace _ ["StartedOpeningVolatileDB"]) _ = Just Info
    severityFor (Namespace _ ["StartedOpeningLgrDB"]) _ = Just Info
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["OpenedDB"]) = Just
      "The ChainDB was opened."
    documentFor (Namespace _ ["ClosedDB"]) = Just
      "The ChainDB was closed."
    documentFor (Namespace _ ["OpenedImmutableDB"]) = Just
      "The ImmDB was opened."
    documentFor (Namespace _ ["OpenedVolatileDB"]) = Just
      "The VolatileDB was opened."
    documentFor (Namespace _ ["OpenedLgrDB"]) = Just
      "The LedgerDB was opened."
    documentFor (Namespace _ ["StartedOpeningDB"]) = Just
      "The ChainDB is being opened."
    documentFor (Namespace _ ["StartedOpeningImmutableDB"]) = Just
      "The ImmDB is being opened."
    documentFor (Namespace _ ["StartedOpeningVolatileDB"]) = Just
      "The VolatileDB is being opened."
    documentFor (Namespace _ ["StartedOpeningLgrDB"]) = Just
      "The LedgerDB is being opened."
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["OpenedDB"]
      , Namespace [] ["ClosedDB"]
      , Namespace [] ["OpenedImmutableDB"]
      , Namespace [] ["OpenedVolatileDB"]
      , Namespace [] ["OpenedLgrDB"]
      , Namespace [] ["StartedOpeningDB"]
      , Namespace [] ["StartedOpeningImmutableDB"]
      , Namespace [] ["StartedOpeningVolatileDB"]
      , Namespace [] ["StartedOpeningLgrDB"]
      ]

--------------------------------------------------------------------------------
-- IteratorEvent
--------------------------------------------------------------------------------

instance  ( StandardHash blk
          , ConvertRawHash blk
          ) => LogFormatting (ChainDB.TraceIteratorEvent blk) where
  forHuman (ChainDB.UnknownRangeRequested ev') = forHumanOrMachine ev'
  forHuman (ChainDB.BlockMissingFromVolatileDB realPt) = mconcat
    [ "This block is no longer in the VolatileDB because it has been garbage"
    , " collected. It might now be in the ImmDB if it was part of the"
    , " current chain. Block: " <> renderRealPoint realPt
    ]
  forHuman (ChainDB.StreamFromImmutableDB sFrom sTo) = mconcat
    [ "Stream only from the ImmDB. StreamFrom:" <> showT sFrom
    , " StreamTo: " <> showT sTo
    ]
  forHuman (ChainDB.StreamFromBoth sFrom sTo pts) = mconcat
    [ "Stream from both the VolatileDB and the ImmDB."
    , " StreamFrom: " <> showT sFrom <> " StreamTo: " <> showT sTo
    , " Points: " <> showT (map renderRealPoint pts)
    ]
  forHuman (ChainDB.StreamFromVolatileDB sFrom sTo pts) = mconcat
    [ "Stream only from the VolatileDB."
    , " StreamFrom: " <> showT sFrom <> " StreamTo: " <> showT sTo
    , " Points: " <> showT (map renderRealPoint pts)
    ]
  forHuman (ChainDB.BlockWasCopiedToImmutableDB pt) = mconcat
    [ "This block has been garbage collected from the VolatileDB is now"
    , " found and streamed from the ImmDB. Block: " <> renderRealPoint pt
    ]
  forHuman (ChainDB.BlockGCedFromVolatileDB pt) = mconcat
    [ "This block no longer in the VolatileDB and isn't in the ImmDB"
    , " either; it wasn't part of the current chain. Block: " <> renderRealPoint pt
    ]
  forHuman ChainDB.SwitchBackToVolatileDB = "SwitchBackToVolatileDB"

  forMachine _dtal (ChainDB.UnknownRangeRequested unkRange) =
    mconcat [ "kind" .= String "UnknownRangeRequested"
             , "range" .= String (showT unkRange)
             ]
  forMachine _dtal (ChainDB.StreamFromVolatileDB streamFrom streamTo realPt) =
    mconcat [ "kind" .= String "StreamFromVolatileDB"
             , "from" .= String (showT streamFrom)
             , "to" .= String (showT streamTo)
             , "point" .= String (Text.pack . show $ map renderRealPoint realPt)
             ]
  forMachine _dtal (ChainDB.StreamFromImmutableDB streamFrom streamTo) =
    mconcat [ "kind" .= String "StreamFromImmutableDB"
             , "from" .= String (showT streamFrom)
             , "to" .= String (showT streamTo)
             ]
  forMachine _dtal (ChainDB.StreamFromBoth streamFrom streamTo realPt) =
    mconcat [ "kind" .= String "StreamFromBoth"
             , "from" .= String (showT streamFrom)
             , "to" .= String (showT streamTo)
             , "point" .= String (Text.pack . show $ map renderRealPoint realPt)
             ]
  forMachine _dtal (ChainDB.BlockMissingFromVolatileDB realPt) =
    mconcat [ "kind" .= String "BlockMissingFromVolatileDB"
             , "point" .= String (renderRealPoint realPt)
             ]
  forMachine _dtal (ChainDB.BlockWasCopiedToImmutableDB realPt) =
    mconcat [ "kind" .= String "BlockWasCopiedToImmutableDB"
             , "point" .= String (renderRealPoint realPt)
             ]
  forMachine _dtal (ChainDB.BlockGCedFromVolatileDB realPt) =
    mconcat [ "kind" .= String "BlockGCedFromVolatileDB"
             , "point" .= String (renderRealPoint realPt)
             ]
  forMachine _dtal ChainDB.SwitchBackToVolatileDB =
    mconcat ["kind" .= String "SwitchBackToVolatileDB"
             ]

instance MetaTrace (ChainDB.TraceIteratorEvent blk) where
    namespaceFor (ChainDB.UnknownRangeRequested ur) =
      nsPrependInner "UnknownRangeRequested" (namespaceFor ur)
    namespaceFor ChainDB.StreamFromVolatileDB {} =
      Namespace [] ["StreamFromVolatileDB"]
    namespaceFor ChainDB.StreamFromImmutableDB {} =
      Namespace [] ["StreamFromImmutableDB"]
    namespaceFor ChainDB.StreamFromBoth {} =
      Namespace [] ["StreamFromBoth"]
    namespaceFor ChainDB.BlockMissingFromVolatileDB {} =
      Namespace [] ["BlockMissingFromVolatileDB"]
    namespaceFor ChainDB.BlockWasCopiedToImmutableDB {} =
      Namespace [] ["BlockWasCopiedToImmutableDB"]
    namespaceFor ChainDB.BlockGCedFromVolatileDB {} =
      Namespace [] ["BlockGCedFromVolatileDB"]
    namespaceFor ChainDB.SwitchBackToVolatileDB {} =
      Namespace [] ["SwitchBackToVolatileDB"]


    severityFor (Namespace out ("UnknownRangeRequested" : tl))
                (Just (ChainDB.UnknownRangeRequested ur)) =
      severityFor (Namespace out tl) (Just ur)
    severityFor (Namespace out ("UnknownRangeRequested" : tl)) Nothing =
      severityFor (Namespace out tl :: Namespace (ChainDB.UnknownRange blk)) Nothing
    severityFor _ _ = Just Debug

    privacyFor (Namespace out ("UnknownRangeRequested" : tl))
                (Just (ChainDB.UnknownRangeRequested ev')) =
      privacyFor (Namespace out tl) (Just ev')
    privacyFor (Namespace out ("UnknownRangeRequested" : tl)) Nothing =
      privacyFor (Namespace out tl ::
        Namespace (ChainDB.UnknownRange blk)) Nothing
    privacyFor _ _ = Just Public

    detailsFor (Namespace out ("UnknownRangeRequested" : tl))
                (Just (ChainDB.UnknownRangeRequested ev')) =
      detailsFor (Namespace out tl) (Just ev')
    detailsFor (Namespace out ("UnknownRangeRequested" : tl)) Nothing =
      detailsFor (Namespace out tl ::
        Namespace (ChainDB.UnknownRange blk)) Nothing
    detailsFor _ _ = Just DNormal

    documentFor (Namespace out ("UnknownRangeRequested" : tl)) =
      documentFor (Namespace out tl :: Namespace (ChainDB.UnknownRange blk))
    documentFor (Namespace _ ["StreamFromVolatileDB"]) = Just
       "Stream only from the VolatileDB."
    documentFor (Namespace _ ["StreamFromImmutableDB"]) = Just
      "Stream only from the ImmDB."
    documentFor (Namespace _ ["StreamFromBoth"]) = Just
      "Stream from both the VolatileDB and the ImmDB."
    documentFor (Namespace _ ["BlockMissingFromVolatileDB"]) = Just $ mconcat
      [ "A block is no longer in the VolatileDB because it has been garbage"
      , " collected. It might now be in the ImmDB if it was part of the"
      , " current chain."
      ]
    documentFor (Namespace _ ["BlockWasCopiedToImmutableDB"]) = Just $ mconcat
      [ "A block that has been garbage collected from the VolatileDB is now"
      , " found and streamed from the ImmDB."
      ]
    documentFor (Namespace _ ["BlockGCedFromVolatileDB"]) = Just $ mconcat
      [ "A block is no longer in the VolatileDB and isn't in the ImmDB"
      , " either; it wasn't part of the current chain."
      ]
    documentFor (Namespace _ ["SwitchBackToVolatileDB"]) = Just $ mconcat
      [ "We have streamed one or more blocks from the ImmDB that were part"
      , " of the VolatileDB when initialising the iterator. Now, we have to look"
      , " back in the VolatileDB again because the ImmDB doesn't have the"
      , " next block we're looking for."
      ]
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["StreamFromVolatileDB"]
      , Namespace [] ["StreamFromImmutableDB"]
      , Namespace [] ["StreamFromBoth"]
      , Namespace [] ["BlockMissingFromVolatileDB"]
      , Namespace [] ["BlockWasCopiedToImmutableDB"]
      , Namespace [] ["BlockGCedFromVolatileDB"]
      , Namespace [] ["SwitchBackToVolatileDB"]
      ]
      ++ map  (nsPrependInner "UnknownRangeRequested")
              (allNamespaces :: [Namespace (ChainDB.UnknownRange blk)])

--------------------------------------------------------------------------------
-- UnknownRange
--------------------------------------------------------------------------------

instance  ( StandardHash blk
          , ConvertRawHash blk
          ) => LogFormatting (ChainDB.UnknownRange blk) where
  forHuman (ChainDB.MissingBlock realPt) =
      "The block at the given point was not found in the ChainDB."
        <> renderRealPoint realPt
  forHuman (ChainDB.ForkTooOld streamFrom) =
      "The requested range forks off too far in the past"
        <> showT streamFrom

  forMachine _dtal (ChainDB.MissingBlock realPt) =
    mconcat [ "kind"  .= String "MissingBlock"
             , "point" .= String (renderRealPoint realPt)
             ]
  forMachine _dtal (ChainDB.ForkTooOld streamFrom) =
    mconcat [ "kind" .= String "ForkTooOld"
             , "from" .= String (showT streamFrom)
             ]

instance MetaTrace (ChainDB.UnknownRange blk) where
    namespaceFor ChainDB.MissingBlock {} = Namespace [] ["MissingBlock"]
    namespaceFor ChainDB.ForkTooOld {} = Namespace []  ["ForkTooOld"]

    severityFor _ _ = Just Debug

    documentFor (Namespace _ ["MissingBlock"]) = Just
      ""
    documentFor (Namespace _ ["ForkTooOld"]) = Just
      ""
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["MissingBlock"]
      , Namespace [] ["ForkTooOld"]
      ]

-- --------------------------------------------------------------------------------
-- -- LedgerDB.TraceEvent
-- --------------------------------------------------------------------------------

instance ( StandardHash blk
         , ConvertRawHash blk)
         => LogFormatting (LedgerDB.TraceEvent blk) where

  forMachine dtals (LedgerDB.LedgerDBSnapshotEvent ev) = forMachine dtals ev
  forMachine dtals (LedgerDB.LedgerReplayEvent ev) = forMachine dtals ev
  forMachine dtals (LedgerDB.LedgerDBForkerEvent ev) = forMachine dtals ev
  forMachine dtals (LedgerDB.LedgerDBFlavorImplEvent ev) = forMachine dtals ev

  forHuman (LedgerDB.LedgerDBSnapshotEvent ev) = forHuman ev
  forHuman (LedgerDB.LedgerReplayEvent ev) = forHuman ev
  forHuman (LedgerDB.LedgerDBForkerEvent ev) = forHuman ev
  forHuman (LedgerDB.LedgerDBFlavorImplEvent ev) = forHuman ev

instance MetaTrace (LedgerDB.TraceEvent blk) where

  namespaceFor (LedgerDB.LedgerDBSnapshotEvent ev) =
    nsPrependInner "Snapshot" (namespaceFor ev)
  namespaceFor (LedgerDB.LedgerReplayEvent ev) =
    nsPrependInner "Replay" (namespaceFor ev)
  namespaceFor (LedgerDB.LedgerDBForkerEvent ev) =
    nsPrependInner "Forker" (namespaceFor ev)
  namespaceFor (LedgerDB.LedgerDBFlavorImplEvent ev) =
    nsPrependInner "Flavor" (namespaceFor ev)

  severityFor (Namespace out ("Snapshot" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (LedgerDB.TraceSnapshotEvent blk)) Nothing
  severityFor (Namespace out ("Snapshot" : tl)) (Just (LedgerDB.LedgerDBSnapshotEvent ev)) =
    severityFor (Namespace out tl :: Namespace (LedgerDB.TraceSnapshotEvent blk)) (Just ev)
  severityFor (Namespace out ("Replay" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayEvent blk)) Nothing
  severityFor (Namespace out ("Replay" : tl)) (Just (LedgerDB.LedgerReplayEvent ev)) =
    severityFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayEvent blk)) (Just ev)
  severityFor (Namespace out ("Forker" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace LedgerDB.TraceForkerEventWithKey) Nothing
  severityFor (Namespace out ("Forker" : tl)) (Just (LedgerDB.LedgerDBForkerEvent ev)) =
    severityFor (Namespace out tl :: Namespace LedgerDB.TraceForkerEventWithKey) (Just ev)
  severityFor (Namespace out ("Flavor" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace LedgerDB.FlavorImplSpecificTrace) Nothing
  severityFor (Namespace out ("Flavor" : tl)) (Just (LedgerDB.LedgerDBFlavorImplEvent ev)) =
    severityFor (Namespace out tl :: Namespace LedgerDB.FlavorImplSpecificTrace) (Just ev)
  severityFor _ _ = Nothing

  documentFor (Namespace o ("Snapshot" : tl)) =
    documentFor (Namespace o tl :: Namespace (LedgerDB.TraceSnapshotEvent blk))
  documentFor (Namespace o ("Replay" : tl)) =
    documentFor (Namespace o tl :: Namespace (LedgerDB.TraceReplayEvent blk))
  documentFor (Namespace o ("Forker" : tl)) =
    documentFor (Namespace o tl :: Namespace LedgerDB.TraceForkerEventWithKey)
  documentFor (Namespace o ("Flavor" : tl)) =
    documentFor (Namespace o tl :: Namespace LedgerDB.FlavorImplSpecificTrace)
  documentFor _ = Nothing

  allNamespaces =
       map (nsPrependInner "Snapshot")
         (allNamespaces :: [Namespace (LedgerDB.TraceSnapshotEvent blk)])
    ++ map (nsPrependInner "Replay")
         (allNamespaces :: [Namespace (LedgerDB.TraceReplayEvent blk)])
    ++ map (nsPrependInner "Forker")
         (allNamespaces :: [Namespace LedgerDB.TraceForkerEventWithKey])
    ++ map (nsPrependInner "Flavor")
         (allNamespaces :: [Namespace LedgerDB.FlavorImplSpecificTrace])

instance ( StandardHash blk
         , ConvertRawHash blk)
         => LogFormatting (LedgerDB.TraceSnapshotEvent blk) where
  forHuman (LedgerDB.TookSnapshot snap pt RisingEdge) =
    Text.unwords [ "Taking ledger snapshot"
                 , showT snap
                 , "at"
                 , renderRealPointAsPhrase pt
                 ]
  forHuman (LedgerDB.TookSnapshot snap pt (FallingEdgeWith t)) =
    Text.unwords [ "Took ledger snapshot"
                 , showT snap
                 , "at"
                 , renderRealPointAsPhrase pt
                 , ", duration:"
                 , showT t
                 ]
  forHuman (LedgerDB.DeletedSnapshot snap) =
    Text.unwords ["Deleted old snapshot", showT snap]
  forHuman (LedgerDB.InvalidSnapshot snap failure) =
    Text.unwords [ "Invalid snapshot"
                 , showT snap
                 , showT failure
                 , context
                 ]
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

  forMachine dtals (LedgerDB.TookSnapshot snap pt enclosedTiming) =
    mconcat [ "kind" .= String "TookSnapshot"
             , "snapshot" .= forMachine dtals snap
             , "tip" .= show pt
             , "enclosedTime" .= enclosedTiming
             ]
  forMachine dtals (LedgerDB.DeletedSnapshot snap) =
    mconcat [ "kind" .= String "DeletedSnapshot"
             , "snapshot" .= forMachine dtals snap ]
  forMachine dtals (LedgerDB.InvalidSnapshot snap failure) =
    mconcat [ "kind" .= String "InvalidSnapshot"
            , "snapshot" .= forMachine dtals snap
            , "failure" .= show failure ]

instance MetaTrace (LedgerDB.TraceSnapshotEvent blk) where
    namespaceFor LedgerDB.TookSnapshot {} = Namespace [] ["TookSnapshot"]
    namespaceFor LedgerDB.DeletedSnapshot {} = Namespace [] ["DeletedSnapshot"]
    namespaceFor LedgerDB.InvalidSnapshot {} = Namespace [] ["InvalidSnapshot"]

    severityFor  (Namespace _ ["TookSnapshot"]) _ = Just Info
    severityFor  (Namespace _ ["DeletedSnapshot"]) _ = Just Debug
    severityFor  (Namespace _ ["InvalidSnapshot"]) _ = Just Error
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["TookSnapshot"]) = Just $ mconcat
         [ "A snapshot is being written to disk. Two events will be traced, one"
         , " for when the node starts taking the snapshot and another one for"
         , " when the snapshot has been written to the disk."
         ]
    documentFor (Namespace _ ["DeletedSnapshot"]) = Just
          "A snapshot was deleted from the disk."
    documentFor (Namespace _ ["InvalidSnapshot"]) = Just $ mconcat
         [ "An on disk snapshot was invalid. Unless it was suffixed or"
         , " seems to be from an old node or different backend, it will"
         , " be deleted"
         ]
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["TookSnapshot"]
      , Namespace [] ["DeletedSnapshot"]
      , Namespace [] ["InvalidSnapshot"]
      ]

--------------------------------------------------------------------------------
-- LedgerDB TraceReplayEvent
--------------------------------------------------------------------------------

instance (StandardHash blk, ConvertRawHash blk)
          => LogFormatting (LedgerDB.TraceReplayEvent blk) where

  forHuman (LedgerDB.TraceReplayStartEvent ev') = forHuman ev'
  forHuman (LedgerDB.TraceReplayProgressEvent ev') = forHuman ev'

  forMachine dtal (LedgerDB.TraceReplayStartEvent ev') = forMachine dtal ev'
  forMachine dtal (LedgerDB.TraceReplayProgressEvent ev') = forMachine dtal ev'

instance (StandardHash blk, ConvertRawHash blk)
          => LogFormatting (LedgerDB.TraceReplayStartEvent blk) where
  forHuman LedgerDB.ReplayFromGenesis =
      "Replaying ledger from genesis"
  forHuman (LedgerDB.ReplayFromSnapshot snap (LedgerDB.ReplayStart tip')) =
      "Replaying ledger from snapshot " <> showT snap <> " at " <>
        renderPointAsPhrase tip'

  forMachine _dtal LedgerDB.ReplayFromGenesis =
      mconcat [ "kind" .= String "ReplayFromGenesis" ]
  forMachine dtal (LedgerDB.ReplayFromSnapshot snap tip') =
      mconcat [ "kind" .= String "ReplayFromSnapshot"
               , "snapshot" .= forMachine dtal snap
               , "tip" .= showT tip' ]

instance (StandardHash blk, ConvertRawHash blk)
          => LogFormatting (LedgerDB.TraceReplayProgressEvent blk) where
  forHuman (LedgerDB.ReplayedBlock
              pt
              _ledgerEvents
              (LedgerDB.ReplayStart replayFrom)
              (LedgerDB.ReplayGoal replayTo)) =
          let fromSlot = withOrigin 0 id $ unSlotNo <$> pointSlot replayFrom
              atSlot   = unSlotNo $ realPointSlot pt
              atDiff   = atSlot - fromSlot
              toSlot   = withOrigin 0 id $ unSlotNo <$> pointSlot replayTo
              toDiff   = toSlot - fromSlot
          in
             "Replayed block: slot "
          <> showT atSlot
          <> " out of "
          <> showT toSlot
          <> ". Progress: "
          <> showProgressT (fromIntegral atDiff) (fromIntegral toDiff)
          <> "%"

  forMachine _dtal (LedgerDB.ReplayedBlock
                      pt
                      _ledgerEvents
                      _
                      (LedgerDB.ReplayGoal replayTo)) =
      mconcat [ "kind" .= String "ReplayedBlock"
               , "slot" .= unSlotNo (realPointSlot pt)
               , "tip"  .= withOrigin 0 unSlotNo (pointSlot replayTo) ]

instance MetaTrace (LedgerDB.TraceReplayEvent blk) where
    namespaceFor (LedgerDB.TraceReplayStartEvent ev) =
      nsPrependInner "ReplayStart" (namespaceFor ev)
    namespaceFor (LedgerDB.TraceReplayProgressEvent ev) =
      nsPrependInner "ReplayProgress" (namespaceFor ev)

    severityFor (Namespace out ("ReplayStart" : tl)) Nothing =
      severityFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayStartEvent blk)) Nothing
    severityFor (Namespace out ("ReplayStart" : tl)) (Just (LedgerDB.TraceReplayStartEvent ev)) =
      severityFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayStartEvent blk)) (Just ev)
    severityFor (Namespace out ("ReplayProgress" : tl)) Nothing =
      severityFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayProgressEvent blk)) Nothing
    severityFor (Namespace out ("ReplayProgress" : tl)) (Just (LedgerDB.TraceReplayProgressEvent ev)) =
      severityFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayProgressEvent blk)) (Just ev)
    severityFor _ _ = Nothing

    documentFor (Namespace out ("ReplayStart" : tl)) =
      documentFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayStartEvent blk))
    documentFor (Namespace out ("ReplayProgress" : tl)) =
      documentFor (Namespace out tl :: Namespace (LedgerDB.TraceReplayProgressEvent blk))
    documentFor _ = Nothing

    allNamespaces =
      map (nsPrependInner "ReplayStart")
        (allNamespaces :: [Namespace (LedgerDB.TraceReplayStartEvent blk)])
      ++ map (nsPrependInner "ReplayProgress")
        (allNamespaces :: [Namespace (LedgerDB.TraceReplayProgressEvent blk)])

instance MetaTrace (LedgerDB.TraceReplayStartEvent blk) where
    namespaceFor LedgerDB.ReplayFromGenesis {} = Namespace [] ["ReplayFromGenesis"]
    namespaceFor LedgerDB.ReplayFromSnapshot {} = Namespace [] ["ReplayFromSnapshot"]

    severityFor  (Namespace _ ["ReplayFromGenesis"]) _ = Just Info
    severityFor  (Namespace _ ["ReplayFromSnapshot"]) _ = Just Info
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["ReplayFromGenesis"]) = Just $ mconcat
      [ "There were no LedgerDB snapshots on disk, so we're replaying all"
      , " blocks starting from Genesis against the initial ledger."
      , " The @replayTo@ parameter corresponds to the block at the tip of the"
      , " ImmDB, i.e., the last block to replay."
      ]
    documentFor (Namespace _ ["ReplayFromSnapshot"]) = Just $ mconcat
      [ "There was a LedgerDB snapshot on disk corresponding to the given tip."
      , " We're replaying more recent blocks against it."
      , " The @replayTo@ parameter corresponds to the block at the tip of the"
      , " ImmDB, i.e., the last block to replay."
      ]
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["ReplayFromGenesis"]
      , Namespace [] ["ReplayFromSnapshot"]
      ]

instance MetaTrace (LedgerDB.TraceReplayProgressEvent blk) where
    namespaceFor LedgerDB.ReplayedBlock {} = Namespace [] ["ReplayedBlock"]

    severityFor  (Namespace _ ["ReplayedBlock"]) _ = Just Info
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["ReplayedBlock"]) = Just $ mconcat
      [ "We replayed the given block (reference) on the genesis snapshot"
      , " during the initialisation of the LedgerDB."
      , "\n"
      , " The @blockInfo@ parameter corresponds replayed block and the @replayTo@"
      , " parameter corresponds to the block at the tip of the ImmDB, i.e.,"
      , " the last block to replay."
      ]
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["ReplayedBlock"]
      ]

--------------------------------------------------------------------------------
-- Forker events
--------------------------------------------------------------------------------

instance LogFormatting LedgerDB.TraceForkerEventWithKey where
  forMachine dtals (LedgerDB.TraceForkerEventWithKey k ev) =
    (\ev' -> mconcat [ "key" .= showT k, "event" .= ev' ]) $ forMachine dtals ev
  forHuman (LedgerDB.TraceForkerEventWithKey k ev) =
    "Forker " <> showT k <> ": " <> forHuman ev

instance LogFormatting LedgerDB.TraceForkerEvent where
  forMachine _dtals LedgerDB.ForkerOpen = mempty
  forMachine _dtals LedgerDB.ForkerCloseUncommitted = mempty
  forMachine _dtals LedgerDB.ForkerCloseCommitted = mempty
  forMachine _dtals LedgerDB.ForkerReadTablesStart = mempty
  forMachine _dtals LedgerDB.ForkerReadTablesEnd = mempty
  forMachine _dtals LedgerDB.ForkerRangeReadTablesStart = mempty
  forMachine _dtals LedgerDB.ForkerRangeReadTablesEnd = mempty
  forMachine _dtals LedgerDB.ForkerReadStatistics = mempty
  forMachine _dtals LedgerDB.ForkerPushStart = mempty
  forMachine _dtals LedgerDB.ForkerPushEnd = mempty

  forHuman LedgerDB.ForkerOpen = "Opened forker"
  forHuman LedgerDB.ForkerCloseUncommitted = "Forker closed without committing"
  forHuman LedgerDB.ForkerCloseCommitted = "Forker closed after committing"
  forHuman LedgerDB.ForkerReadTablesStart = "Started to read tables"
  forHuman LedgerDB.ForkerReadTablesEnd = "Finish reading tables"
  forHuman LedgerDB.ForkerRangeReadTablesStart = "Started to range read tables"
  forHuman LedgerDB.ForkerRangeReadTablesEnd = "Finish range reading tables"
  forHuman LedgerDB.ForkerReadStatistics = "Gathering statistics"
  forHuman LedgerDB.ForkerPushStart = "Started to push"
  forHuman LedgerDB.ForkerPushEnd = "Pushed"

instance MetaTrace LedgerDB.TraceForkerEventWithKey where
  namespaceFor (LedgerDB.TraceForkerEventWithKey _ ev) =
    nsCast $ namespaceFor ev
  severityFor ns (Just (LedgerDB.TraceForkerEventWithKey _ ev)) =
    severityFor (nsCast ns) (Just ev)
  severityFor (Namespace out tl) Nothing =
    severityFor (Namespace out tl :: Namespace LedgerDB.TraceForkerEvent) Nothing
  documentFor = documentFor @LedgerDB.TraceForkerEvent . nsCast
  allNamespaces = map nsCast $ allNamespaces @LedgerDB.TraceForkerEvent

instance MetaTrace LedgerDB.TraceForkerEvent where
  namespaceFor LedgerDB.ForkerOpen = Namespace [] ["Open"]
  namespaceFor LedgerDB.ForkerCloseUncommitted = Namespace [] ["CloseUncommitted"]
  namespaceFor LedgerDB.ForkerCloseCommitted = Namespace [] ["CloseCommitted"]
  namespaceFor LedgerDB.ForkerReadTablesStart = Namespace [] ["StartRead"]
  namespaceFor LedgerDB.ForkerReadTablesEnd = Namespace [] ["FinishRead"]
  namespaceFor LedgerDB.ForkerRangeReadTablesStart = Namespace [] ["StartRangeRead"]
  namespaceFor LedgerDB.ForkerRangeReadTablesEnd = Namespace [] ["FinishRangeRead"]
  namespaceFor LedgerDB.ForkerReadStatistics = Namespace [] ["Statistics"]
  namespaceFor LedgerDB.ForkerPushStart = Namespace [] ["StartPush"]
  namespaceFor LedgerDB.ForkerPushEnd = Namespace [] ["FinishPush"]

  severityFor _ _ = Just Debug

  documentFor (Namespace _ ("Open" : _tl)) = Just
   "A forker is being opened"
  documentFor (Namespace _ ("CloseUncommitted" : _tl)) = Just $
   mconcat [ "A forker was closed without being committed."
           , " This is usually the case with forkers that are not opened for chain selection,"
           , " and for forkers on discarded forks"]
  documentFor (Namespace _ ("CloseCommitted" : _tl)) = Just "A forker was committed (the LedgerDB was modified accordingly) and closed"
  documentFor (Namespace _ ("StartRead" : _tl)) = Just "The process for reading ledger tables started"
  documentFor (Namespace _ ("FinishRead" : _tl)) = Just "Values from the ledger tables were read"
  documentFor (Namespace _ ("StartRangeRead" : _tl)) = Just "The process for range reading ledger tables started"
  documentFor (Namespace _ ("FinishRangeRead" : _tl)) = Just "Values from the ledger tables were range-read"
  documentFor (Namespace _ ("Statistics" : _tl)) = Just "Statistics were gathered from the forker"
  documentFor (Namespace _ ("StartPush" : _tl)) = Just "A ledger state is going to be pushed to the forker"
  documentFor (Namespace _ ("FinishPush" : _tl)) = Just "A ledger state was pushed to the forker"
  documentFor _ = Nothing

  allNamespaces = [
      Namespace [] ["Open"]
    , Namespace [] ["CloseUncommitted"]
    , Namespace [] ["CloseCommitted"]
    , Namespace [] ["StartRead"]
    , Namespace [] ["FinishRead"]
    , Namespace [] ["StartRangeRead"]
    , Namespace [] ["FinishRangeRead"]
    , Namespace [] ["Statistics"]
    , Namespace [] ["StartPush"]
    , Namespace [] ["FinishPush"]
    ]

--------------------------------------------------------------------------------
-- Flavor specific trace
--------------------------------------------------------------------------------

instance LogFormatting LedgerDB.FlavorImplSpecificTrace where
  forMachine dtal (LedgerDB.FlavorImplSpecificTraceV1 ev) = forMachine dtal ev
  forMachine dtal (LedgerDB.FlavorImplSpecificTraceV2 ev) = forMachine dtal ev

  forHuman (LedgerDB.FlavorImplSpecificTraceV1 ev) = forHuman ev
  forHuman (LedgerDB.FlavorImplSpecificTraceV2 ev) = forHuman ev

instance MetaTrace LedgerDB.FlavorImplSpecificTrace where
  namespaceFor (LedgerDB.FlavorImplSpecificTraceV1 ev) =
    nsPrependInner "V1" (namespaceFor ev)
  namespaceFor (LedgerDB.FlavorImplSpecificTraceV2 ev) =
    nsPrependInner "V2" (namespaceFor ev)

  severityFor (Namespace out ("V1" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTrace) Nothing
  severityFor (Namespace out ("V1" : tl)) (Just (LedgerDB.FlavorImplSpecificTraceV1 ev)) =
    severityFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTrace) (Just ev)
  severityFor (Namespace out ("V2" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace V2.FlavorImplSpecificTrace) Nothing
  severityFor (Namespace out ("V2" : tl)) (Just (LedgerDB.FlavorImplSpecificTraceV2 ev)) =
    severityFor (Namespace out tl :: Namespace V2.FlavorImplSpecificTrace) (Just ev)
  severityFor _ _ = Nothing

  documentFor (Namespace out ("V1" : tl)) =
    documentFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTrace)
  documentFor (Namespace out ("V2" : tl)) =
    documentFor (Namespace out tl :: Namespace V2.FlavorImplSpecificTrace)
  documentFor _ = Nothing

  allNamespaces =
       map (nsPrependInner "V1")
         (allNamespaces :: [Namespace V1.FlavorImplSpecificTrace])
    ++ map (nsPrependInner "V2")
         (allNamespaces :: [Namespace V2.FlavorImplSpecificTrace])

--------------------------------------------------------------------------------
-- V1
--------------------------------------------------------------------------------

instance LogFormatting V1.FlavorImplSpecificTrace where
  forMachine dtal (V1.FlavorImplSpecificTraceInMemory ev) = forMachine dtal ev
  forMachine dtal (V1.FlavorImplSpecificTraceOnDisk ev) = forMachine dtal ev

  forHuman (V1.FlavorImplSpecificTraceInMemory ev) = forHuman ev
  forHuman (V1.FlavorImplSpecificTraceOnDisk ev) = forHuman ev

instance LogFormatting V1.FlavorImplSpecificTraceInMemory where
  forMachine _dtal V1.InMemoryBackingStoreInitialise = mempty
  forMachine dtal (V1.InMemoryBackingStoreTrace ev) = forMachine dtal ev

  forHuman V1.InMemoryBackingStoreInitialise = "Initializing in-memory backing store"
  forHuman (V1.InMemoryBackingStoreTrace ev) = forHuman ev

instance LogFormatting V1.FlavorImplSpecificTraceOnDisk where
  forMachine _dtal (V1.OnDiskBackingStoreInitialise limits) =
    mconcat [ "limits" .= showT limits ]
  forMachine dtal (V1.OnDiskBackingStoreTrace ev) = forMachine dtal ev

  forHuman (V1.OnDiskBackingStoreInitialise limits) = "Initializing on-disk backing store with limits " <> showT limits
  forHuman (V1.OnDiskBackingStoreTrace ev) = forHuman ev

instance LogFormatting V1.BackingStoreTrace where
  forMachine _dtals V1.BSOpening = mempty
  forMachine _dtals (V1.BSOpened p) =
    maybe mempty (\p' -> mconcat [ "path" .= showT p' ]) p
  forMachine _dtals (V1.BSInitialisingFromCopy p) =
    mconcat [ "path" .= showT p ]
  forMachine _dtals (V1.BSInitialisedFromCopy p) =
    mconcat [ "path" .= showT p ]
  forMachine _dtals (V1.BSInitialisingFromValues sl) =
    mconcat [ "slot" .= showT sl ]
  forMachine _dtals (V1.BSInitialisedFromValues sl) =
    mconcat [ "slot" .= showT sl ]
  forMachine _dtals V1.BSClosing = mempty
  forMachine _dtals V1.BSAlreadyClosed = mempty
  forMachine _dtals V1.BSClosed = mempty
  forMachine _dtals (V1.BSCopying p) =
    mconcat [ "path" .= showT p ]
  forMachine _dtals (V1.BSCopied p) =
    mconcat [ "path" .= showT p ]
  forMachine _dtals V1.BSCreatingValueHandle = mempty
  forMachine _dtals V1.BSCreatedValueHandle = mempty
  forMachine _dtals (V1.BSWriting s) =
    mconcat [ "slot" .= showT s ]
  forMachine _dtals (V1.BSWritten s1 s2) =
    mconcat [ "old" .= showT s1, "new" .= showT s2 ]
  forMachine _dtals (V1.BSValueHandleTrace i _ev) =
    maybe mempty (\i' -> mconcat ["idx" .= showT i']) i
instance LogFormatting V1.BackingStoreValueHandleTrace where
  forMachine _dtals V1.BSVHClosing = mempty
  forMachine _dtals V1.BSVHAlreadyClosed = mempty
  forMachine _dtals V1.BSVHClosed = mempty
  forMachine _dtals V1.BSVHRangeReading = mempty
  forMachine _dtals V1.BSVHRangeRead = mempty
  forMachine _dtals V1.BSVHReading = mempty
  forMachine _dtals V1.BSVHRead = mempty
  forMachine _dtals V1.BSVHStatting = mempty
  forMachine _dtals V1.BSVHStatted = mempty

instance MetaTrace V1.FlavorImplSpecificTrace where
  namespaceFor (V1.FlavorImplSpecificTraceInMemory ev) =
    nsPrependInner "InMemory" (namespaceFor ev)
  namespaceFor (V1.FlavorImplSpecificTraceOnDisk ev) =
    nsPrependInner "OnDisk" (namespaceFor ev)

  severityFor (Namespace out ("InMemory" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTraceInMemory) Nothing
  severityFor (Namespace out ("InMemory" : tl)) (Just (V1.FlavorImplSpecificTraceInMemory ev)) =
    severityFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTraceInMemory) (Just ev)
  severityFor (Namespace out ("OnDisk" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTraceOnDisk) Nothing
  severityFor (Namespace out ("OnDisk" : tl)) (Just (V1.FlavorImplSpecificTraceOnDisk ev)) =
    severityFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTraceOnDisk) (Just ev)
  severityFor _ _ = Nothing

  documentFor (Namespace out ("InMemory" : tl)) =
    documentFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTraceInMemory)
  documentFor (Namespace out ("OnDisk" : tl)) =
    documentFor (Namespace out tl :: Namespace V1.FlavorImplSpecificTraceOnDisk)
  documentFor _ = Nothing

  allNamespaces =
    map (nsPrependInner "InMemory")
        (allNamespaces :: [Namespace V1.FlavorImplSpecificTraceInMemory])
    ++ map (nsPrependInner "OnDisk")
        (allNamespaces :: [Namespace V1.FlavorImplSpecificTraceOnDisk])

instance MetaTrace V1.FlavorImplSpecificTraceInMemory where
  namespaceFor V1.InMemoryBackingStoreInitialise = Namespace [] ["Initialise"]
  namespaceFor (V1.InMemoryBackingStoreTrace bsTrace) =
    nsPrependInner "BackingStoreEvent" (namespaceFor bsTrace)

  severityFor (Namespace _ ("Initialise" : _)) _ = Just Debug
  severityFor (Namespace out ("BackingStoreEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace V1.BackingStoreTrace) Nothing
  severityFor (Namespace out ("BackingStoreEvent" : tl)) (Just (V1.InMemoryBackingStoreTrace ev)) =
    severityFor (Namespace out tl :: Namespace V1.BackingStoreTrace) (Just ev)
  severityFor _ _ = Nothing

  documentFor (Namespace _ ("Initialise" : _)) = Just
    "Backing store is being initialised"
  documentFor (Namespace out ("BackingStoreEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace V1.BackingStoreTrace)
  documentFor _ = Nothing

  allNamespaces =
    Namespace [] ["Initialise"]
    : map (nsPrependInner "BackingStoreEvent")
          (allNamespaces :: [Namespace V1.BackingStoreTrace])

instance MetaTrace V1.FlavorImplSpecificTraceOnDisk where
  namespaceFor V1.OnDiskBackingStoreInitialise{} =
    Namespace [] ["Initialise"]
  namespaceFor (V1.OnDiskBackingStoreTrace ev) =
    nsPrependInner "BackingStoreEvent" (namespaceFor ev)

  severityFor (Namespace _ ("Initialise" : _)) _ = Just Debug
  severityFor (Namespace out ("BackingStoreEvent" : tl)) Nothing =
    severityFor (Namespace out tl :: Namespace V1.BackingStoreTrace) Nothing
  severityFor (Namespace out ("BackingStoreEvent" : tl)) (Just (V1.OnDiskBackingStoreTrace ev)) =
    severityFor (Namespace out tl :: Namespace V1.BackingStoreTrace) (Just ev)
  severityFor _ _ = Nothing

  documentFor (Namespace _ ("Initialise" : _)) = Just
    "Backing store is being initialised"
  documentFor (Namespace out ("BackingStoreEvent" : tl)) =
    documentFor (Namespace out tl :: Namespace V1.BackingStoreTrace)
  documentFor _ = Nothing

  allNamespaces =
    Namespace [] ["Initialise"]
    : map (nsPrependInner "BackingStoreEvent")
          (allNamespaces :: [Namespace V1.BackingStoreTrace])

instance MetaTrace V1.BackingStoreTrace where
  namespaceFor V1.BSOpening = Namespace [] ["Opening"]
  namespaceFor V1.BSOpened{} = Namespace [] ["Opened"]
  namespaceFor V1.BSInitialisingFromCopy{} =
    Namespace [] ["InitialisingFromCopy"]
  namespaceFor V1.BSInitialisedFromCopy{} =
    Namespace [] ["InitialisedFromCopy"]
  namespaceFor V1.BSInitialisingFromValues{} =
    Namespace [] ["InitialisingFromValues"]
  namespaceFor V1.BSInitialisedFromValues{} =
    Namespace [] ["InitialisedFromValues"]
  namespaceFor V1.BSClosing = Namespace [] ["Closing"]
  namespaceFor V1.BSAlreadyClosed = Namespace [] ["AlreadyClosed"]
  namespaceFor V1.BSClosed = Namespace [] ["Closed"]
  namespaceFor V1.BSCopying{} = Namespace [] ["Copying"]
  namespaceFor V1.BSCopied{} = Namespace [] ["Copied"]
  namespaceFor V1.BSCreatingValueHandle = Namespace [] ["CreatingValueHandle"]
  namespaceFor V1.BSCreatedValueHandle = Namespace [] ["CreatedValueHandle"]
  namespaceFor (V1.BSValueHandleTrace _ bsValueHandleTrace) =
    nsPrependInner "ValueHandleTrace" (namespaceFor bsValueHandleTrace)
  namespaceFor V1.BSWriting{} = Namespace [] ["Writing"]
  namespaceFor V1.BSWritten{} = Namespace [] ["Written"]

  severityFor (Namespace _ ("Opening" : _)) _ = Just Debug
  severityFor (Namespace _ ("Opened" : _)) _ = Just Debug
  severityFor (Namespace _ ("InitialisingFromCopy" : _)) _ = Just Debug
  severityFor (Namespace _ ("InitialisedFromCopy" : _)) _ = Just Debug
  severityFor (Namespace _ ("InitialisingFromValues" : _)) _ = Just Debug
  severityFor (Namespace _ ("InitialisedFromValues" : _)) _ = Just Debug
  severityFor (Namespace _ ("Closing" : _)) _ = Just Debug
  severityFor (Namespace _ ("AlreadyClosed" : _)) _ = Just Debug
  severityFor (Namespace _ ("Closed" : _)) _ = Just Debug
  severityFor (Namespace _ ("Copying" : _)) _ = Just Debug
  severityFor (Namespace _ ("Copied" : _)) _ = Just Debug
  severityFor (Namespace _ ("CreatingValueHandle" : _)) _ = Just Debug
  severityFor (Namespace _ ("CreatedValueHandle" : _)) _ = Just Debug
  severityFor (Namespace out ("ValueHandleTrace" : t1)) Nothing =
    severityFor
      (Namespace out t1 :: Namespace V1.BackingStoreValueHandleTrace)
      Nothing
  severityFor
    (Namespace out ("ValueHandleTrace" : t1))
    (Just (V1.BSValueHandleTrace _ bsValueHandleTrace)) =
      severityFor
        (Namespace out t1 :: Namespace V1.BackingStoreValueHandleTrace)
        (Just bsValueHandleTrace)
  severityFor (Namespace _ ("Writing" : _)) _ = Just Debug
  severityFor (Namespace _ ("Written" : _)) _ = Just Debug
  severityFor _ _ = Nothing

  documentFor (Namespace _ ("Opening" : _ )) = Just
    "Opening backing store"
  documentFor (Namespace _ ("Opened" : _ )) = Just
    "Backing store opened"
  documentFor (Namespace _ ("InitialisingFromCopy" : _ )) = Just
    "Initialising backing store from copy"
  documentFor (Namespace _ ("InitialisedFromCopy" : _ )) = Just
    "Backing store initialised from copy"
  documentFor (Namespace _ ("InitialisingFromValues" : _ )) = Just
    "Initialising backing store from values"
  documentFor (Namespace _ ("InitialisedFromValues" : _ )) = Just
    "Backing store initialised from values"
  documentFor (Namespace _ ("Closing" : _ )) = Just
    "Closing backing store"
  documentFor (Namespace _ ("AlreadyClosed" : _ )) = Just
    "Backing store is already closed"
  documentFor (Namespace _ ("Closed" : _ )) = Just
    "Backing store closed"
  documentFor (Namespace _ ("Copying" : _ )) = Just
    "Copying backing store"
  documentFor (Namespace _ ("Copied" : _ )) = Just
    "Backing store copied"
  documentFor (Namespace _ ("CreatingValueHandle" : _ )) = Just
    "Creating value handle for backing store"
  documentFor (Namespace _ ("CreatedValueHandle" : _ )) = Just
    "Value handle for backing store created"
  documentFor (Namespace out ("ValueHandleTrace" : t1 )) =
    documentFor (Namespace out t1 :: Namespace V1.BackingStoreValueHandleTrace)
  documentFor (Namespace _ ("Writing" : _ )) = Just
    "Writing backing store"
  documentFor (Namespace _ ("Written" : _ )) = Just
    "Backing store written"
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["Opening"]
    , Namespace [] ["Opened"]
    , Namespace [] ["InitialisingFromCopy"]
    , Namespace [] ["InitialisedFromCopy"]
    , Namespace [] ["InitialisingFromValues"]
    , Namespace [] ["InitialisedFromValues"]
    , Namespace [] ["Closing"]
    , Namespace [] ["AlreadyClosed"]
    , Namespace [] ["Closed"]
    , Namespace [] ["Copying"]
    , Namespace [] ["Copied"]
    , Namespace [] ["CreatingValueHandle"]
    , Namespace [] ["CreatedValueHandle"]
    , Namespace [] ["Writing"]
    , Namespace [] ["Written"]
    ] ++ map (nsPrependInner "ValueHandleTrace")
             (allNamespaces :: [Namespace V1.BackingStoreValueHandleTrace])


instance MetaTrace V1.BackingStoreValueHandleTrace where
  namespaceFor V1.BSVHClosing = Namespace [] ["Closing"]
  namespaceFor V1.BSVHAlreadyClosed = Namespace [] ["AlreadyClosed"]
  namespaceFor V1.BSVHClosed = Namespace [] ["Closed"]
  namespaceFor V1.BSVHRangeReading = Namespace [] ["RangeReading"]
  namespaceFor V1.BSVHRangeRead = Namespace [] ["RangeRead"]
  namespaceFor V1.BSVHReading = Namespace [] ["Reading"]
  namespaceFor V1.BSVHRead = Namespace [] ["Read"]
  namespaceFor V1.BSVHStatting = Namespace [] ["Statting"]
  namespaceFor V1.BSVHStatted = Namespace [] ["Statted"]

  severityFor (Namespace _ ("Closing" : _ )) _ = Just Debug
  severityFor (Namespace _ ("AlreadyClosed" : _ )) _ = Just Debug
  severityFor (Namespace _ ("Closed" : _ )) _ = Just Debug
  severityFor (Namespace _ ("RangeReading" : _ )) _ = Just Debug
  severityFor (Namespace _ ("RangeRead" : _ )) _ = Just Debug
  severityFor (Namespace _ ("Reading" : _ )) _ = Just Debug
  severityFor (Namespace _ ("Read" : _ )) _ = Just Debug
  severityFor (Namespace _ ("Statting" : _ )) _ = Just Debug
  severityFor (Namespace _ ("Statted" : _ )) _ = Just Debug
  severityFor _ _ = Nothing

  documentFor (Namespace _ ("Closing" : _ )) = Just
    "Closing backing store value handle"
  documentFor (Namespace _ ("AlreadyClosed" : _ )) = Just
    "Backing store value handle already clsoed"
  documentFor (Namespace _ ("Closed" : _ )) = Just
    "Backing store value handle closed"
  documentFor (Namespace _ ("RangeReading" : _ )) = Just
    "Reading range for backing store value handle"
  documentFor (Namespace _ ("RangeRead" : _ )) = Just
    "Range for backing store value handle read"
  documentFor (Namespace _ ("Reading" : _ )) = Just
    "Reading backing store value handle"
  documentFor (Namespace _ ("Read" : _ )) = Just
    "Backing store value handle read"
  documentFor (Namespace _ ("Statting" : _ )) = Just
    "Statting backing store value handle"
  documentFor (Namespace _ ("Statted" : _ )) = Just
    "Backing store value handle statted"
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["Closing"]
    , Namespace [] ["AlreadyClosed"]
    , Namespace [] ["Closed"]
    , Namespace [] ["RangeReading"]
    , Namespace [] ["RangeRead"]
    , Namespace [] ["Reading"]
    , Namespace [] ["Read"]
    , Namespace [] ["Statting"]
    , Namespace [] ["Statted"]
    ]

instance LogFormatting V2.FlavorImplSpecificTrace where
  forMachine _dtal V2.FlavorImplSpecificTraceInMemory =
    mconcat [ "kind" .= String "InMemory" ]
  forMachine _dtal V2.FlavorImplSpecificTraceOnDisk =
    mconcat [ "kind" .= String "OnDisk" ]

  forHuman V2.FlavorImplSpecificTraceInMemory =
    "An in-memory backing store event was traced"
  forHuman V2.FlavorImplSpecificTraceOnDisk =
    "An on-disk backing store event was traced"

instance MetaTrace V2.FlavorImplSpecificTrace where
  namespaceFor V2.FlavorImplSpecificTraceInMemory =
    Namespace [] ["InMemory"]
  namespaceFor V2.FlavorImplSpecificTraceOnDisk =
    Namespace [] ["OnDisk"]

  severityFor (Namespace _ ["InMemory"]) _ = Just Info
  severityFor (Namespace _ ["OnDisk"])   _ = Just Info
  severityFor _                          _ = Nothing

  -- suspicious
  privacyFor (Namespace _ ["InMemory"]) _ = Just Public
  privacyFor (Namespace _ ["OnDisk"])   _ = Just Public
  privacyFor _                          _ = Just Public

  documentFor (Namespace _ ["InMemory"]) =
    Just "An in-memory backing store event"
  documentFor (Namespace _ ["OnDisk"]) =
    Just "An on-disk backing store event"
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["InMemory"]
    , Namespace [] ["OnDisk"]
    ]

--------------------------------------------------------------------------------
-- ImmDB.TraceEvent
--------------------------------------------------------------------------------

instance (ConvertRawHash blk, StandardHash blk)
  => LogFormatting (ImmDB.TraceEvent blk) where
    forMachine _dtal ImmDB.NoValidLastLocation =
      mconcat [ "kind" .= String "NoValidLastLocation" ]
    forMachine _dtal (ImmDB.ValidatedLastLocation chunkNo immTip) =
      mconcat [ "kind" .= String "ValidatedLastLocation"
               , "chunkNo" .= String (renderChunkNo chunkNo)
               , "immTip" .= String (renderTipHash immTip)
               , "blockNo" .= String (renderTipBlockNo immTip)
               ]
    forMachine dtal (ImmDB.ChunkValidationEvent traceChunkValidation) =
      forMachine dtal traceChunkValidation
    forMachine _dtal (ImmDB.DeletingAfter immTipWithInfo) =
      mconcat [ "kind" .= String "DeletingAfter"
               , "immTipHash" .= String (renderWithOrigin renderTipHash immTipWithInfo)
               , "immTipBlockNo" .= String (renderWithOrigin renderTipBlockNo immTipWithInfo)
               ]
    forMachine _dtal ImmDB.DBAlreadyClosed =
      mconcat [ "kind" .= String "DBAlreadyClosed" ]
    forMachine _dtal ImmDB.DBClosed =
      mconcat [ "kind" .= String "DBClosed" ]
    forMachine dtal (ImmDB.TraceCacheEvent cacheEv) =
      forMachine dtal cacheEv
    forMachine _dtal (ImmDB.ChunkFileDoesntFit expectPrevHash actualPrevHash) =
      mconcat [ "kind" .= String "ChunkFileDoesntFit"
               , "expectedPrevHash" .= String (renderChainHash (Text.decodeLatin1 .
                                              toRawHash (Proxy @blk)) expectPrevHash)
               , "actualPrevHash" .= String (renderChainHash (Text.decodeLatin1 .
                                              toRawHash (Proxy @blk)) actualPrevHash)
               ]
    forMachine _dtal (ImmDB.Migrating txt) =
      mconcat [ "kind" .= String "Migrating"
               , "info" .= String txt
               ]

    forHuman ImmDB.NoValidLastLocation =
          "No valid last location was found. Starting from Genesis."
    forHuman (ImmDB.ValidatedLastLocation cn t) =
            "Found a valid last location at chunk "
          <> showT cn
          <> " with tip "
          <> renderRealPoint (ImmDB.tipToRealPoint t)
          <> "."
    forHuman (ImmDB.ChunkValidationEvent e) = case e of
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
    forHuman (ImmDB.ChunkFileDoesntFit ch1 ch2 ) =
          "Chunk file doesn't fit. The hash of the block " <> showT ch2 <> " doesn't match the previous hash of the first block in the current epoch: " <> showT ch1 <> "."
    forHuman (ImmDB.Migrating t) = "Migrating: " <> t
    forHuman (ImmDB.DeletingAfter wot) = "Deleting chunk files after " <> showT wot
    forHuman ImmDB.DBAlreadyClosed {} = "Immutable DB was already closed. Double closing."
    forHuman ImmDB.DBClosed {} = "Closed Immutable DB."
    forHuman (ImmDB.TraceCacheEvent ev') = "Cache event: " <> case ev' of
          ImmDB.TraceCurrentChunkHit   cn   curr -> "Current chunk hit: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunkHit      cn   curr -> "Past chunk hit: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunkMiss     cn   curr -> "Past chunk miss: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunkEvict    cn   curr -> "Past chunk evict: " <> showT cn <> ", cache size: " <> showT curr
          ImmDB.TracePastChunksExpired cns  curr -> "Past chunks expired: " <> showT cns <> ", cache size: " <> showT curr


instance MetaTrace (ImmDB.TraceEvent blk) where
    namespaceFor ImmDB.NoValidLastLocation {} = Namespace [] ["NoValidLastLocation"]
    namespaceFor ImmDB.ValidatedLastLocation {} = Namespace [] ["ValidatedLastLocation"]
    namespaceFor (ImmDB.ChunkValidationEvent ev) =
      nsPrependInner "ChunkValidation" (namespaceFor ev)
    namespaceFor ImmDB.ChunkFileDoesntFit {} = Namespace [] ["ChunkFileDoesntFit"]
    namespaceFor ImmDB.Migrating {} = Namespace [] ["Migrating"]
    namespaceFor ImmDB.DeletingAfter {} = Namespace [] ["DeletingAfter"]
    namespaceFor ImmDB.DBAlreadyClosed {} = Namespace [] ["DBAlreadyClosed"]
    namespaceFor ImmDB.DBClosed {} = Namespace [] ["DBClosed"]
    namespaceFor (ImmDB.TraceCacheEvent ev) =
      nsPrependInner "CacheEvent" (namespaceFor ev)

    severityFor  (Namespace _ ["NoValidLastLocation"]) _ = Just Info
    severityFor  (Namespace _ ["ValidatedLastLocation"]) _ = Just Info
    severityFor (Namespace out ("ChunkValidation" : tl))
                    (Just (ImmDB.ChunkValidationEvent ev')) =
      severityFor (Namespace out tl) (Just ev')
    severityFor (Namespace out ("ChunkValidation" : tl)) Nothing =
      severityFor (Namespace out tl :: Namespace (ImmDB.TraceChunkValidation blk ImmDB.ChunkNo)) Nothing

    severityFor (Namespace out ("ChunkValidationEvent" : tl)) Nothing =
      severityFor (Namespace out tl :: Namespace (ImmDB.TraceChunkValidation blk chunkNo)) Nothing
    severityFor  (Namespace _ ["ChunkFileDoesntFit"]) _ = Just Warning
    severityFor  (Namespace _ ["Migrating"]) _ = Just Debug
    severityFor  (Namespace _ ["DeletingAfter"]) _ = Just Debug
    severityFor  (Namespace _ ["DBAlreadyClosed"]) _ = Just Error
    severityFor  (Namespace _ ["DBClosed"]) _ = Just Info
    severityFor (Namespace out ("CacheEvent" : tl))
                    (Just (ImmDB.TraceCacheEvent ev')) =
      severityFor (Namespace out tl) (Just ev')
    severityFor (Namespace out ("CacheEvent" : tl)) Nothing =
      severityFor (Namespace out tl :: Namespace ImmDB.TraceCacheEvent) Nothing
    severityFor _ _ = Nothing

    privacyFor (Namespace out ("ChunkValidation" : tl))
                    (Just (ImmDB.ChunkValidationEvent ev')) =
      privacyFor (Namespace out tl) (Just ev')
    privacyFor (Namespace out ("ChunkValidationEvent" : tl)) Nothing =
      privacyFor (Namespace out tl :: Namespace (ImmDB.TraceChunkValidation blk chunkNo)) Nothing
    privacyFor (Namespace out ("CacheEvent" : tl))
                    (Just (ImmDB.TraceCacheEvent ev')) =
      privacyFor (Namespace out tl) (Just ev')
    privacyFor _ _ = Just Public

    detailsFor (Namespace out ("ChunkValidation" : tl))
                    (Just (ImmDB.ChunkValidationEvent ev')) =
      detailsFor (Namespace out tl) (Just ev')
    detailsFor (Namespace out ("ChunkValidationEvent" : tl)) Nothing =
      detailsFor (Namespace out tl :: Namespace (ImmDB.TraceChunkValidation blk chunkNo)) Nothing
    detailsFor (Namespace out ("CacheEvent" : tl))
                    (Just (ImmDB.TraceCacheEvent ev')) =
      detailsFor (Namespace out tl) (Just ev')
    detailsFor _ _ = Just DNormal

    documentFor (Namespace _ ["NoValidLastLocation"]) = Just
      "No valid last location was found"
    documentFor (Namespace _ ["ValidatedLastLocation"]) = Just
      "The last location was validatet"
    documentFor (Namespace o ("ChunkValidation" : tl)) =
       documentFor (Namespace o tl :: Namespace (ImmDB.TraceChunkValidation blk chunkNo))
    documentFor (Namespace _ ["ChunkFileDoesntFit"]) = Just $ mconcat
      [ "The hash of the last block in the previous epoch doesn't match the"
      , " previous hash of the first block in the current epoch"
      ]
    documentFor (Namespace _ ["Migrating"]) = Just
      "Performing a migration of the on-disk files."
    documentFor (Namespace _ ["DeletingAfter"]) = Just
      "Delete after"
    documentFor (Namespace _ ["DBAlreadyClosed"]) = Just
      ""
    documentFor (Namespace _ ["DBClosed"]) = Just
      "Closing the immutable DB"
    documentFor (Namespace o ("CacheEvent" : tl)) =
       documentFor (Namespace o tl :: Namespace ImmDB.TraceCacheEvent)
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["NoValidLastLocation"]
      , Namespace [] ["ValidatedLastLocation"]
      , Namespace [] ["ChunkFileDoesntFit"]
      , Namespace [] ["Migrating"]
      , Namespace [] ["DeletingAfter"]
      , Namespace [] ["DBAlreadyClosed"]
      , Namespace [] ["DBClosed"]
      ]
      ++ map  (nsPrependInner "ChunkValidation")
              (allNamespaces :: [Namespace (ImmDB.TraceChunkValidation blk chunkNo)])
      ++ map  (nsPrependInner "CacheEvent")
              (allNamespaces :: [Namespace ImmDB.TraceCacheEvent])

--------------------------------------------------------------------------------
-- ImmDB.TraceChunkValidation
--------------------------------------------------------------------------------

instance ConvertRawHash blk => LogFormatting (ImmDB.TraceChunkValidation blk ImmDB.ChunkNo) where
    forMachine _dtal (ImmDB.RewriteSecondaryIndex chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.RewriteSecondaryIndex"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.RewritePrimaryIndex chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.RewritePrimaryIndex"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.MissingPrimaryIndex chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.MissingPrimaryIndex"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.MissingSecondaryIndex chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.MissingSecondaryIndex"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.InvalidPrimaryIndex chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidPrimaryIndex"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.InvalidSecondaryIndex chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidSecondaryIndex"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.InvalidChunkFile chunkNo
                      (ImmDB.ChunkErrHashMismatch hashPrevBlock prevHashOfBlock)) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidChunkFile.ChunkErrHashMismatch"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 , "hashPrevBlock" .= String (Text.decodeLatin1 . toRawHash (Proxy @blk) $ hashPrevBlock)
                 , "prevHashOfBlock" .= String (renderChainHash (Text.decodeLatin1 . toRawHash (Proxy @blk)) prevHashOfBlock)
                 ]
    forMachine dtal (ImmDB.InvalidChunkFile chunkNo (ImmDB.ChunkErrCorrupt pt)) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidChunkFile.ChunkErrCorrupt"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 , "block" .= String (renderPointForDetails dtal pt)
                 ]
    forMachine _dtal (ImmDB.ValidatedChunk chunkNo _) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.ValidatedChunk"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.MissingChunkFile chunkNo) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.MissingChunkFile"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 ]
    forMachine _dtal (ImmDB.InvalidChunkFile chunkNo (ImmDB.ChunkErrRead readIncErr)) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.InvalidChunkFile.ChunkErrRead"
                 , "chunkNo" .= String (renderChunkNo chunkNo)
                 , "error" .= String (showT readIncErr)
                 ]
    forMachine _dtal (ImmDB.StartedValidatingChunk initialChunk finalChunk) =
        mconcat [ "kind" .= String "TraceImmutableDBEvent.StartedValidatingChunk"
                 , "initialChunk" .= renderChunkNo initialChunk
                 , "finalChunk" .= renderChunkNo finalChunk
                 ]

instance MetaTrace (ImmDB.TraceChunkValidation blk chunkNo) where
    namespaceFor ImmDB.StartedValidatingChunk {} = Namespace [] ["StartedValidatingChunk"]
    namespaceFor ImmDB.ValidatedChunk {} = Namespace [] ["ValidatedChunk"]
    namespaceFor ImmDB.MissingChunkFile {} = Namespace [] ["MissingChunkFile"]
    namespaceFor ImmDB.InvalidChunkFile {} = Namespace [] ["InvalidChunkFile"]
    namespaceFor ImmDB.MissingPrimaryIndex {} = Namespace [] ["MissingPrimaryIndex"]
    namespaceFor ImmDB.MissingSecondaryIndex {} = Namespace [] ["MissingSecondaryIndex"]
    namespaceFor ImmDB.InvalidPrimaryIndex {} = Namespace [] ["InvalidPrimaryIndex"]
    namespaceFor ImmDB.InvalidSecondaryIndex {} = Namespace [] ["InvalidSecondaryIndex"]
    namespaceFor ImmDB.RewritePrimaryIndex {} = Namespace [] ["RewritePrimaryIndex"]
    namespaceFor ImmDB.RewriteSecondaryIndex {} = Namespace [] ["RewriteSecondaryIndex"]

    severityFor  (Namespace _ ["StartedValidatingChunk"]) _ = Just Info
    severityFor  (Namespace _ ["ValidatedChunk"]) _ = Just Info
    severityFor  (Namespace _ ["MissingChunkFile"]) _ = Just Warning
    severityFor  (Namespace _ ["InvalidChunkFile"]) _ = Just Warning
    severityFor  (Namespace _ ["MissingPrimaryIndex"]) _ = Just Warning
    severityFor  (Namespace _ ["MissingSecondaryIndex"]) _ = Just Warning
    severityFor  (Namespace _ ["InvalidPrimaryIndex"]) _ = Just Warning
    severityFor  (Namespace _ ["InvalidSecondaryIndex"]) _ = Just Warning
    severityFor  (Namespace _ ["RewritePrimaryIndex"]) _ = Just Warning
    severityFor  (Namespace _ ["RewriteSecondaryIndex"]) _ = Just Warning
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["StartedValidatingChunk"]) = Just
      ""
    documentFor (Namespace _ ["ValidatedChunk"]) = Just
      ""
    documentFor (Namespace _ ["MissingChunkFile"]) = Just
      ""
    documentFor (Namespace _ ["InvalidChunkFile"]) = Just
      ""
    documentFor (Namespace _ ["MissingPrimaryIndex"]) = Just
      ""
    documentFor (Namespace _ ["MissingSecondaryIndex"]) = Just
      ""
    documentFor (Namespace _ ["InvalidPrimaryIndex"]) = Just
      ""
    documentFor (Namespace _ ["InvalidSecondaryIndex"]) = Just
      ""
    documentFor (Namespace _ ["RewritePrimaryIndex"]) = Just
      ""
    documentFor (Namespace _ ["RewriteSecondaryIndex"]) = Just
      ""
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["StartedValidatingChunk"]
      , Namespace [] ["ValidatedChunk"]
      , Namespace [] ["MissingChunkFile"]
      , Namespace [] ["InvalidChunkFile"]
      , Namespace [] ["MissingPrimaryIndex"]
      , Namespace [] ["MissingSecondaryIndex"]
      , Namespace [] ["InvalidPrimaryIndex"]
      , Namespace [] ["InvalidSecondaryIndex"]
      , Namespace [] ["RewritePrimaryIndex"]
      , Namespace [] ["RewriteSecondaryIndex"]
      ]

--------------------------------------------------------------------------------
-- ImmDB.TraceCacheEvent
--------------------------------------------------------------------------------

instance LogFormatting ImmDB.TraceCacheEvent where
    forMachine _dtal (ImmDB.TraceCurrentChunkHit chunkNo nbPastChunksInCache) =
          mconcat [ "kind" .= String "TraceCurrentChunkHit"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
    forMachine _dtal (ImmDB.TracePastChunkHit chunkNo nbPastChunksInCache) =
          mconcat [ "kind" .= String "TracePastChunkHit"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
    forMachine _dtal (ImmDB.TracePastChunkMiss chunkNo nbPastChunksInCache) =
          mconcat [ "kind" .= String "TracePastChunkMiss"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
    forMachine _dtal (ImmDB.TracePastChunkEvict chunkNo nbPastChunksInCache) =
          mconcat [ "kind" .= String "TracePastChunkEvict"
                   , "chunkNo" .= String (renderChunkNo chunkNo)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]
    forMachine _dtal (ImmDB.TracePastChunksExpired chunkNos nbPastChunksInCache) =
          mconcat [ "kind" .= String "TracePastChunksExpired"
                   , "chunkNos" .= String (Text.pack . show $ map renderChunkNo chunkNos)
                   , "noPastChunks" .= String (showT nbPastChunksInCache)
                   ]

instance MetaTrace ImmDB.TraceCacheEvent where
    namespaceFor ImmDB.TraceCurrentChunkHit {} = Namespace [] ["CurrentChunkHit"]
    namespaceFor ImmDB.TracePastChunkHit {} = Namespace [] ["PastChunkHit"]
    namespaceFor ImmDB.TracePastChunkMiss {} = Namespace [] ["PastChunkMiss"]
    namespaceFor ImmDB.TracePastChunkEvict {} = Namespace [] ["PastChunkEvict"]
    namespaceFor ImmDB.TracePastChunksExpired {} = Namespace [] ["PastChunkExpired"]

    severityFor  (Namespace _ ["CurrentChunkHit"]) _ = Just Debug
    severityFor  (Namespace _ ["PastChunkHit"]) _ = Just Debug
    severityFor  (Namespace _ ["PastChunkMiss"]) _ = Just Debug
    severityFor  (Namespace _ ["PastChunkEvict"]) _ = Just Debug
    severityFor  (Namespace _ ["PastChunkExpired"]) _ = Just Debug
    severityFor  _ _ = Nothing

    documentFor (Namespace _ ["CurrentChunkHit"]) = Just
      "Current chunk found in the cache."
    documentFor (Namespace _ ["PastChunkHit"]) = Just
      "Past chunk found in the cache"
    documentFor (Namespace _ ["PastChunkMiss"]) = Just
      "Past chunk was not found in the cache"
    documentFor (Namespace _ ["PastChunkEvict"]) = Just $ mconcat
      [ "The least recently used past chunk was evicted because the cache"
      , " was full."
      ]
    documentFor (Namespace _ ["PastChunkExpired"]) = Just
      ""
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["CurrentChunkHit"]
      , Namespace [] ["PastChunkHit"]
      , Namespace [] ["PastChunkMiss"]
      , Namespace [] ["PastChunkEvict"]
      , Namespace [] ["PastChunkExpired"]
      ]

--------------------------------------------------------------------------------
-- VolDb.TraceEvent
--------------------------------------------------------------------------------

instance StandardHash blk => LogFormatting (VolDB.TraceEvent blk) where
    forMachine _dtal VolDB.DBAlreadyClosed =
      mconcat [ "kind" .= String "DBAlreadyClosed"]
    forMachine _dtal (VolDB.BlockAlreadyHere blockId) =
      mconcat [ "kind" .= String "BlockAlreadyHere"
               , "blockId" .= String (showT blockId)
               ]
    forMachine _dtal (VolDB.Truncate pErr fsPath blockOffset) =
      mconcat [ "kind" .= String "Truncate"
               , "parserError" .= String (showT pErr)
               , "file" .= String (showT fsPath)
               , "blockOffset" .= String (showT blockOffset)
               ]
    forMachine _dtal (VolDB.InvalidFileNames fsPaths) =
      mconcat [ "kind" .= String "InvalidFileNames"
               , "files" .= String (Text.pack . show $ map show fsPaths)
              ]
    forMachine _dtal VolDB.DBClosed =
      mconcat [ "kind" .= String "DBClosed" ]

instance MetaTrace (VolDB.TraceEvent blk) where
    namespaceFor VolDB.DBAlreadyClosed {} = Namespace [] ["DBAlreadyClosed"]
    namespaceFor VolDB.BlockAlreadyHere {} = Namespace [] ["BlockAlreadyHere"]
    namespaceFor VolDB.Truncate {} = Namespace [] ["Truncate"]
    namespaceFor VolDB.InvalidFileNames {} = Namespace [] ["InvalidFileNames"]
    namespaceFor VolDB.DBClosed {} = Namespace [] ["DBClosed"]

    severityFor  (Namespace _ ["DBAlreadyClosed"]) _ = Just Debug
    severityFor  (Namespace _ ["BlockAlreadyHere"]) _ = Just Debug
    severityFor  (Namespace _ ["Truncate"]) _ = Just Debug
    severityFor  (Namespace _ ["InvalidFileNames"]) _ = Just Debug
    severityFor  (Namespace _ ["DBClosed"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor  (Namespace _ ["DBAlreadyClosed"]) = Just
      "When closing the DB it was found it is closed already."
    documentFor  (Namespace _ ["BlockAlreadyHere"]) = Just
      "A block was found to be already in the DB."
    documentFor  (Namespace _ ["Truncate"]) =  Just
      "Truncates a file up to offset because of the error."
    documentFor  (Namespace _ ["InvalidFileNames"]) = Just
      "Reports a list of invalid file paths."
    documentFor  (Namespace _ ["DBClosed"]) = Just
      "Closing the volatile DB"
    documentFor _ = Nothing

    allNamespaces =
      [ Namespace [] ["DBAlreadyClosed"]
      , Namespace [] ["BlockAlreadyHere"]
      , Namespace [] ["Truncate"]
      , Namespace [] ["InvalidFileNames"]
      , Namespace [] ["DBClosed"]
      ]


--------------------------------------------------------------------------------
-- ChainInformation
--------------------------------------------------------------------------------

sevLedgerEvent :: LedgerEvent blk -> SeverityS
sevLedgerEvent (LedgerUpdate _)  = Notice
sevLedgerEvent (LedgerWarning _) = Critical

showProgressT :: Int -> Int -> Text
showProgressT chunkNo outOf =
  Text.pack (showFFloat
          (Just 2)
          (100 * fromIntegral chunkNo / fromIntegral outOf :: Float)
          mempty)

data ChainInformation = ChainInformation
  { slots                :: Word64
  , blocks               :: Word64
  , density              :: Rational
    -- ^ the actual number of blocks created over the maximum expected number
    -- of blocks that could be created over the span of the last @k@ blocks.
  , epoch                :: EpochNo
    -- ^ In which epoch is the tip of the current chain
  , slotInEpoch          :: Word64
    -- ^ Relative slot number of the tip of the current chain within the
    -- epoch.
  , blocksUncoupledDelta :: Int64
  , tipBlockHash :: Text
    -- ^ Hash of the last adopted block.
  , tipBlockParentHash :: Text
    -- ^ Hash of the parent block of the last adopted block.
  , tipBlockIssuerVerificationKeyHash :: BlockIssuerVerificationKeyHash
    -- ^ Hash of the last adopted block issuer's verification key.
  }


chainInformation
  :: forall blk. HasHeader (Header blk)
  => HasIssuer blk
  => ConvertRawHash blk
  => ChainDB.SelectionChangedInfo blk
  -> AF.AnchoredFragment (Header blk)
  -> AF.AnchoredFragment (Header blk) -- ^ New fragment.
  -> Int64
  -> ChainInformation
chainInformation selChangedInfo oldFrag frag blocksUncoupledDelta = ChainInformation
    { slots = unSlotNo $ fromWithOrigin 0 (AF.headSlot frag)
    , blocks = unBlockNo $ fromWithOrigin (BlockNo 1) (AF.headBlockNo frag)
    , density = fragmentChainDensity frag
    , epoch = ChainDB.newTipEpoch selChangedInfo
    , slotInEpoch = ChainDB.newTipSlotInEpoch selChangedInfo
    , blocksUncoupledDelta = blocksUncoupledDelta
    , tipBlockHash = renderHeaderHash (Proxy @blk) $ realPointHash (ChainDB.newTipPoint selChangedInfo)
    , tipBlockParentHash = renderChainHash (Text.decodeLatin1 . B16.encode . toRawHash (Proxy @blk)) $ AF.headHash oldFrag
    , tipBlockIssuerVerificationKeyHash = tipIssuerVkHash
    }
  where
    tipIssuerVkHash :: BlockIssuerVerificationKeyHash
    tipIssuerVkHash = either (const NoBlockIssuer) getIssuerVerificationKeyHash (AF.head frag)

fragmentChainDensity ::
  HasHeader (Header blk)
  => AF.AnchoredFragment (Header blk) -> Rational
fragmentChainDensity frag = calcDensity blockD slotD
  where
    calcDensity :: Word64 -> Word64 -> Rational
    calcDensity bl sl
      | sl > 0 = toRational bl / toRational sl
      | otherwise = 0
    slotN  = unSlotNo $ fromWithOrigin 0 (AF.headSlot frag)
    -- Slot of the tip - slot @k@ blocks back. Use 0 as the slot for genesis
    -- includes EBBs
    slotD   = slotN
            - unSlotNo (fromWithOrigin 0 (AF.lastSlot frag))
    -- Block numbers start at 1. We ignore the genesis EBB, which has block number 0.
    blockD = blockN - firstBlock
    blockN = unBlockNo $ fromWithOrigin (BlockNo 1) (AF.headBlockNo frag)
    firstBlock = case unBlockNo . blockNo <$> AF.last frag of
      -- Empty fragment, no blocks. We have that @blocks = 1 - 1 = 0@
      Left _  -> 1
      -- The oldest block is the genesis EBB with block number 0,
      -- don't let it contribute to the number of blocks
      Right 0 -> 1
      Right b -> b

--------------------------------------------------------------------------------
-- Other orophans
--------------------------------------------------------------------------------

instance LogFormatting LedgerDB.DiskSnapshot where
  forMachine DDetailed snap =
    mconcat [ "kind" .= String "snapshot"
             , "snapshot" .= String (Text.pack $ show snap) ]
  forMachine _ _snap = mconcat [ "kind" .= String "snapshot" ]


instance ( StandardHash blk
         , LogFormatting (ValidationErr (BlockProtocol blk))
         , LogFormatting (OtherHeaderEnvelopeError blk)
         )
      => LogFormatting (HeaderError blk) where
  forMachine dtal (HeaderProtocolError err) =
    mconcat
      [ "kind" .= String "HeaderProtocolError"
      , "error" .= forMachine dtal err
      ]
  forMachine dtal (HeaderEnvelopeError err) =
    mconcat
      [ "kind" .= String "HeaderEnvelopeError"
      , "error" .= forMachine dtal err
      ]

instance ( StandardHash blk
         , LogFormatting (OtherHeaderEnvelopeError blk)
         )
      => LogFormatting (HeaderEnvelopeError blk) where
  forMachine _dtal (UnexpectedBlockNo expect act) =
    mconcat
      [ "kind" .= String "UnexpectedBlockNo"
      , "expected" .= condense expect
      , "actual" .= condense act
      ]
  forMachine _dtal (UnexpectedSlotNo expect act) =
    mconcat
      [ "kind" .= String "UnexpectedSlotNo"
      , "expected" .= condense expect
      , "actual" .= condense act
      ]
  forMachine _dtal (UnexpectedPrevHash expect act) =
    mconcat
      [ "kind" .= String "UnexpectedPrevHash"
      , "expected" .= String (Text.pack $ show expect)
      , "actual" .= String (Text.pack $ show act)
      ]

  forMachine _dtal (CheckpointMismatch blockNumber hdrHashExpected hdrHashActual) =
    mconcat
      [ "kind" .= String "CheckpointMismatch"
      , "blockNo" .= String (Text.pack $ show blockNumber)
      , "expected" .= String (Text.pack $ show hdrHashExpected)
      , "actual" .= String (Text.pack $ show hdrHashActual)
      ]

  forMachine dtal (OtherHeaderEnvelopeError err) =
    forMachine dtal err


instance (   LogFormatting (LedgerError blk)
           , LogFormatting (HeaderError blk))
        => LogFormatting (ExtValidationError blk) where
    forMachine dtal (ExtValidationErrorLedger err) = forMachine dtal err
    forMachine dtal (ExtValidationErrorHeader err) = forMachine dtal err

    forHuman (ExtValidationErrorLedger err) =  forHumanOrMachine err
    forHuman (ExtValidationErrorHeader err) =  forHumanOrMachine err

    asMetrics (ExtValidationErrorLedger err) =  asMetrics err
    asMetrics (ExtValidationErrorHeader err) =  asMetrics err

instance (Show (PBFT.PBftVerKeyHash c))
      => LogFormatting (PBFT.PBftValidationErr c) where
  forMachine _dtal (PBFT.PBftInvalidSignature text) =
    mconcat
      [ "kind" .= String "PBftInvalidSignature"
      , "error" .= String text
      ]
  forMachine _dtal (PBFT.PBftNotGenesisDelegate vkhash _ledgerView) =
    mconcat
      [ "kind" .= String "PBftNotGenesisDelegate"
      , "vk" .= String (Text.pack $ show vkhash)
      ]
  forMachine _dtal (PBFT.PBftExceededSignThreshold vkhash numForged) =
    mconcat
      [ "kind" .= String "PBftExceededSignThreshold"
      , "vk" .= String (Text.pack $ show vkhash)
      , "numForged" .= String (Text.pack (show numForged))
      ]
  forMachine _dtal PBFT.PBftInvalidSlot =
    mconcat
      [ "kind" .= String "PBftInvalidSlot"
      ]

instance (Show (PBFT.PBftVerKeyHash c))
      => LogFormatting (PBFT.PBftCannotForge c) where
  forMachine _dtal (PBFT.PBftCannotForgeInvalidDelegation vkhash) =
    mconcat
      [ "kind" .= String "PBftCannotForgeInvalidDelegation"
      , "vk" .= String (Text.pack $ show vkhash)
      ]
  forMachine _dtal (PBFT.PBftCannotForgeThresholdExceeded numForged) =
    mconcat
      [ "kind" .= String "PBftCannotForgeThresholdExceeded"
      , "numForged" .= numForged
      ]
