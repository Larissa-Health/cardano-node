{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Tracing.Peer
  ( Peer (..)
  , getCurrentPeers
  , ppPeer
  , tracePeers
  ) where

import           Cardano.BM.Data.LogItem (LOContent (..))
import           Cardano.BM.Trace (traceNamedObject)
import           Cardano.BM.Tracing
import           Cardano.Node.Orphans ()
import           Cardano.Node.Queries
import           Ouroboros.Consensus.Block (Header)
import           Ouroboros.Consensus.HeaderValidation (HeaderWithTime (..))
import           Ouroboros.Consensus.MiniProtocol.ChainSync.Client (ChainSyncClientHandle,
                   csCandidate, cschcMap, viewChainSyncState)
import           Ouroboros.Consensus.Util.Orphans ()
import qualified Ouroboros.Network.AnchoredFragment as Net
import           Ouroboros.Network.Block (unSlotNo)
import qualified Ouroboros.Network.Block as Net
import qualified Ouroboros.Network.BlockFetch.ClientRegistry as Net
import           Ouroboros.Network.BlockFetch.ClientState (PeerFetchInFlight (..),
                   PeerFetchStatus (..), readFetchClientState)
import           Ouroboros.Network.ConnectionId (remoteAddress)
import           Ouroboros.Network.NodeToNode (RemoteAddress)

import qualified Control.Concurrent.Class.MonadSTM.Strict as STM
import           Control.DeepSeq (NFData (..))
import           Data.Aeson (ToJSON (..), Value (..), toJSON, (.=))
import           Data.Functor ((<&>))
import qualified Data.List as List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as Text
import           GHC.Generics (Generic)
import           Text.Printf (printf)

import           NoThunks.Class (AllowThunk (..), NoThunks)

{- HLINT ignore "Use =<<" -}
{- HLINT ignore "Use <=<" -}

data Peer blk =
  Peer
  !RemoteConnectionId
  !(Net.AnchoredFragment (Header blk))
  !(PeerFetchStatus (Header blk))
  !(PeerFetchInFlight (Header blk))
  deriving (Generic)
  deriving NoThunks via AllowThunk (Peer blk)

instance NFData (Peer blk) where
    rnf _ = ()

ppPeer :: Peer blk -> Text
ppPeer (Peer cid _af status inflight) =
  Text.pack $ printf "%-15s %-8s %s" (ppCid cid) (ppStatus status) (ppInFlight inflight)

ppCid :: RemoteConnectionId -> String
ppCid = show . remoteAddress

ppInFlight :: PeerFetchInFlight header -> String
ppInFlight f = printf
 "%5s  %3d  %5d  %6d"
 (ppMaxSlotNo $ peerFetchMaxSlotNo f)
 (peerFetchReqsInFlight f)
 (Set.size $ peerFetchBlocksInFlight f)
 (peerFetchBytesInFlight f)

ppMaxSlotNo :: Net.MaxSlotNo -> String
ppMaxSlotNo Net.NoMaxSlotNo = "???"
ppMaxSlotNo (Net.MaxSlotNo x) = show (unSlotNo x)

ppStatus :: PeerFetchStatus header -> String
ppStatus = \case
  PeerFetchStatusShutdown -> "shutdown"
  PeerFetchStatusAberrant -> "aberrant"
  PeerFetchStatusBusy     -> "fetching"
  PeerFetchStatusReady {} -> "ready"
  PeerFetchStatusStarting -> "starting"

getCurrentPeers
  :: forall blk. Net.HasHeader (Header blk)
  => NodeKernelData blk
  -> IO [Peer blk]
getCurrentPeers nkd = mapNodeKernelDataIO extractPeers nkd
                      <&> fromSMaybe mempty
 where
  tuple3pop :: (a, b, c) -> (a, b)
  tuple3pop (a, b, _) = (a, b)

  peerFetchStatusForgetTime :: PeerFetchStatus (HeaderWithTime blk) -> PeerFetchStatus (Header blk)
  peerFetchStatusForgetTime = \case
      PeerFetchStatusShutdown          -> PeerFetchStatusShutdown
      PeerFetchStatusStarting          -> PeerFetchStatusStarting
      PeerFetchStatusAberrant          -> PeerFetchStatusAberrant
      PeerFetchStatusBusy              -> PeerFetchStatusBusy
      PeerFetchStatusReady points idle -> PeerFetchStatusReady (Set.mapMonotonic Net.castPoint points) idle

  peerFetchInFlightForgetTime :: PeerFetchInFlight (HeaderWithTime blk) -> PeerFetchInFlight (Header blk)
  peerFetchInFlightForgetTime inflight =
    inflight {peerFetchBlocksInFlight = Set.mapMonotonic Net.castPoint (peerFetchBlocksInFlight inflight)}

  getCandidates
    :: STM.STM IO (Map peer (ChainSyncClientHandle IO blk))
    -> STM.STM IO (Map peer (Net.AnchoredFragment (Header blk)))
  getCandidates handle = viewChainSyncState handle (Net.mapAnchoredFragment hwtHeader . csCandidate)

  extractPeers :: NodeKernel IO RemoteAddress LocalConnectionId blk
                -> IO [Peer blk]
  extractPeers kernel = do
    peerStates <- fmap tuple3pop <$> ( STM.atomically
                                     . (>>= traverse readFetchClientState)
                                     . Net.readFetchClientsStateVars
                                     . getFetchClientRegistry $ kernel
                                     )
    candidates <- STM.atomically . getCandidates . cschcMap . getChainSyncHandles $ kernel

    let peers = flip Map.mapMaybeWithKey candidates $ \cid af ->
                  maybe Nothing
                        (\(status, inflight) -> Just $ Peer cid af (peerFetchStatusForgetTime status) (peerFetchInFlightForgetTime inflight))
                        $ Map.lookup cid peerStates
    pure . Map.elems $ peers

-- | Trace peers list, it will be forwarded to an external process
--   (for example, to RTView service).
tracePeers
  :: Trace IO Text
  -> [Peer blk]
  -> IO ()
tracePeers tr peers = do
  let tr' = appendName "metrics" tr
  let tr'' = appendName "peersFromNodeKernel" tr'
  meta <- mkLOMeta Notice Public
  traceNamedObject tr'' (meta, LogStructured $ toObject MaximalVerbosity peers)

-- | Instances for converting [Peer blk] to Object.

instance ToObject [Peer blk] where
  toObject MinimalVerbosity _ = mempty
  toObject _ [] = mempty
  toObject verb xs = mconcat
    [ "kind"  .= String "NodeKernelPeers"
    , "peers" .= toJSON
      (List.foldl' (\acc x -> toObject verb x : acc) [] xs)
    ]

instance ToObject (Peer blk) where
  toObject _verb (Peer cid _af status inflight) =
    mconcat [ "peerAddress"   .= String (Text.pack . show . remoteAddress $ cid)
            , "peerStatus"    .= String (Text.pack . ppStatus $ status)
            , "peerSlotNo"    .= String (Text.pack . ppMaxSlotNo . peerFetchMaxSlotNo $ inflight)
            , "peerReqsInF"   .= String (Text.pack . show . peerFetchReqsInFlight $ inflight)
            , "peerBlocksInF" .= String (Text.pack . show . Set.size . peerFetchBlocksInFlight $ inflight)
            , "peerBytesInF"  .= String (Text.pack . show . peerFetchBytesInFlight $ inflight)
            ]
