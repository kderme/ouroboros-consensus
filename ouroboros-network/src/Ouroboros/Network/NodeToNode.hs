{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TypeFamilies        #-}

-- | This is the starting point for a module that will bring together the
-- overall node to node protocol, as a collection of mini-protocols.
--
module Ouroboros.Network.NodeToNode (
    nodeToNodeProtocols
  , NodeToNodeProtocols (..)
  , NodeToNodeVersion (..)
  , NodeToNodeVersionData (..)
  , DictVersion (..)
  , nodeToNodeCodecCBORTerm

  , NetworkConnectTracers (..)
  , nullNetworkConnectTracers
  , connectTo
  , connectTo_V1

  , NetworkServerTracers (..)
  , nullNetworkServerTracers
  , NetworkMutableState (..)
  , newNetworkMutableState
  , newNetworkMutableStateSTM
  , cleanNetworkMutableState
  , withServer
  , withServer_V1

  -- * Subscription Workers
  -- ** IP subscriptin worker
  , IPSubscriptionTarget (..)
  , NetworkIPSubscriptionTracers
  , NetworkSubscriptionTracers (..)
  , nullNetworkSubscriptionTracers
  , SubscriptionParams (..)
  , IPSubscriptionParams
  , ipSubscriptionWorker
  , ipSubscriptionWorker_V1

  -- ** DNS subscription worker
  , DnsSubscriptionTarget (..)
  , DnsSubscriptionParams
  , NetworkDNSSubscriptionTracers (..)
  , nullNetworkDNSSubscriptionTracers
  , dnsSubscriptionWorker
  , dnsSubscriptionWorker_V1

  -- * Re-exports
  , ConnectionId (..)
  , RemoteConnectionId
  , ProtocolLimitFailure
  , Handshake
  , LocalAddresses (..)

  -- ** Error Policies and Peer state
  , ErrorPolicies (..)
  , remoteNetworkErrorPolicy
  , localNetworkErrorPolicy
  , nullErrorPolicies
  , ErrorPolicy (..)
  , SuspendDecision (..)

  -- ** Traces
  , TraceSendRecv (..)
  , SubscriptionTrace (..)
  , DnsTrace (..)
  , ErrorPolicyTrace (..)
  , WithIPList (..)
  , WithDomainName (..)
  , WithAddr (..)
  , HandshakeTr
  ) where

import qualified Control.Concurrent.Async as Async
import           Control.Exception (IOException)
import qualified Data.ByteString.Lazy as BL
import           Data.Time.Clock (DiffTime)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           Data.Void (Void)
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Term as CBOR
import           Codec.Serialise (Serialise (..), DeserialiseFailure)
import           Network.Mux (WithMuxBearer (..))
import qualified Network.Socket as Socket

import           Ouroboros.Network.Driver (TraceSendRecv(..))
import           Ouroboros.Network.Driver.Limits (ProtocolLimitFailure)
import           Ouroboros.Network.Mux
import           Ouroboros.Network.Magic
import           Ouroboros.Network.ErrorPolicy
import           Ouroboros.Network.Protocol.Handshake.Type
import           Ouroboros.Network.Protocol.Handshake.Version hiding (Accept)
import qualified Ouroboros.Network.Protocol.Handshake.Version as V
import           Ouroboros.Network.BlockFetch.Client (BlockFetchProtocolFailure)
import qualified Ouroboros.Network.TxSubmission.Inbound as TxInbound
import qualified Ouroboros.Network.TxSubmission.Outbound as TxOutbound
import           Ouroboros.Network.Socket
import           Ouroboros.Network.Tracers
import           Ouroboros.Network.Subscription.Ip (IPSubscriptionParams, SubscriptionParams (..))
import qualified Ouroboros.Network.Subscription.Ip as Subscription
import           Ouroboros.Network.Subscription.Ip ( IPSubscriptionTarget (..)
                                                   , WithIPList (..)
                                                   , SubscriptionTrace (..)
                                                   )
import           Ouroboros.Network.Subscription.Dns (DnsSubscriptionParams)
import qualified Ouroboros.Network.Subscription.Dns as Subscription
import           Ouroboros.Network.Subscription.Dns ( DnsSubscriptionTarget (..)
                                                    , DnsTrace (..)
                                                    , WithDomainName (..)
                                                    )
import           Ouroboros.Network.Subscription.Worker (LocalAddresses (..))
import           Ouroboros.Network.Snocket

-- The Handshake tracer types are simply terrible.
type HandshakeTr = WithMuxBearer (ConnectionId Socket.SockAddr)
    (TraceSendRecv (Handshake NodeToNodeVersion CBOR.Term))


data NodeToNodeProtocols appType bytes m a b = NodeToNodeProtocols {
    -- | chain-sync mini-protocol
    --
    chainSyncProtocol    :: RunMiniProtocol appType bytes m a b,

    -- | block-fetch mini-protocol
    --
    blockFetchProtocol   :: RunMiniProtocol appType bytes m a b,

    -- | tx-submission mini-protocol
    --
    txSubmissionProtocol :: RunMiniProtocol appType bytes m a b
  }


-- | Make an 'OuroborosApplication' for the bundle of mini-protocols that
-- make up the overall node-to-node protocol.
--
-- This function specifies the wire format protocol numbers.
--
-- The application specific protocol numbers start from 2.  The
-- @'MiniProtocolNum' 0@ is reserved for the 'Handshake' protocol, while
-- @'MiniProtocolNum' 1@ is reserved for DeltaQ messages.
-- 'Handshake' protocol is not included in 'NodeToNodeProtocols' as it runs
-- before mux is started but it reusing 'MuxBearer' to send and receive
-- messages.  Only when the handshake protocol suceedes, we will know which
-- protocols to run / multiplex. 
--
-- These are chosen to not overlap with the node to client protocol numbers (and
-- the handshake protocol number).  This is not essential for correctness, but
-- is helpful to allow a single shared implementation of tools that can analyse
-- both protocols, e.g.  wireshark plugins.
--
nodeToNodeProtocols
  :: NodeToNodeProtocols appType bytes m a b
  -> OuroborosApplication appType bytes m a b
nodeToNodeProtocols NodeToNodeProtocols {
                        chainSyncProtocol,
                        blockFetchProtocol,
                        txSubmissionProtocol
                      } =
    OuroborosApplication [
      MiniProtocol {
        miniProtocolNum    = MiniProtocolNum 2,
        miniProtocolLimits = maximumMiniProtocolLimits,
        miniProtocolRun    = chainSyncProtocol
      }
    , MiniProtocol {
        miniProtocolNum    = MiniProtocolNum 3,
        miniProtocolLimits = maximumMiniProtocolLimits,
        miniProtocolRun    = blockFetchProtocol
      }
    , MiniProtocol {
        miniProtocolNum    = MiniProtocolNum 4,
        miniProtocolLimits = maximumMiniProtocolLimits,
        miniProtocolRun    = txSubmissionProtocol
      }
    ]

  -- TODO: provide sensible limits
  -- https://github.com/input-output-hk/ouroboros-network/issues/575
maximumMiniProtocolLimits :: MiniProtocolLimits
maximumMiniProtocolLimits =
    MiniProtocolLimits {
      maximumIngressQueue = 0xffffffff
    }

-- | Enumeration of node to node protocol versions.
--
data NodeToNodeVersion = NodeToNodeV_1
  deriving (Eq, Ord, Enum, Show, Typeable)

instance Serialise NodeToNodeVersion where
    encode NodeToNodeV_1 = CBOR.encodeWord 1
    decode = do
      tag <- CBOR.decodeWord
      case tag of
        1 -> return NodeToNodeV_1
        _ -> fail "decode NodeToNodeVersion: unknown tag"

-- | Version data for NodeToNode protocol v1
--
newtype NodeToNodeVersionData = NodeToNodeVersionData
  { networkMagic :: NetworkMagic }
  deriving (Eq, Show, Typeable)

instance Acceptable NodeToNodeVersionData where
    acceptableVersion local remote | local == remote = V.Accept
                                   | otherwise =  Refuse $ T.pack $ "version data mismatch: " ++ show local
                                                    ++ " /= " ++ show remote

nodeToNodeCodecCBORTerm :: CodecCBORTerm Text NodeToNodeVersionData
nodeToNodeCodecCBORTerm = CodecCBORTerm {encodeTerm, decodeTerm}
    where
      encodeTerm :: NodeToNodeVersionData -> CBOR.Term
      encodeTerm NodeToNodeVersionData { networkMagic } =
        CBOR.TInt (fromIntegral $ unNetworkMagic networkMagic)

      decodeTerm :: CBOR.Term -> Either Text NodeToNodeVersionData
      decodeTerm (CBOR.TInt x) | x >= 0 && x <= 0xffffffff = Right (NodeToNodeVersionData $ NetworkMagic $ fromIntegral x)
                               | otherwise                 = Left $ T.pack $ "networkMagic out of bound: " <> show x
      decodeTerm t             = Left $ T.pack $ "unknown encoding: " ++ show t


-- | A specialised version of @'Ouroboros.Network.Socket.connectToNode'@.
--
connectTo
  :: Snocket IO Socket.Socket Socket.SockAddr
  -> NetworkConnectTracers Socket.SockAddr NodeToNodeVersion
  -> Versions NodeToNodeVersion
              DictVersion
              (ConnectionId Socket.SockAddr ->
                 OuroborosApplication InitiatorApp BL.ByteString IO a b)
  -> Maybe Socket.SockAddr
  -> Socket.SockAddr
  -> IO ()
connectTo sn =
    connectToNode sn cborTermVersionDataCodec


-- | Like 'connectTo' but specific to 'NodeToNodeV_1'.
--
connectTo_V1
  :: SocketSnocket
  -> NetworkConnectTracers Socket.SockAddr NodeToNodeVersion
  -> NodeToNodeVersionData
  -> (ConnectionId Socket.SockAddr ->
        OuroborosApplication InitiatorApp BL.ByteString IO a b)
  -> Maybe Socket.SockAddr
  -> Socket.SockAddr
  -> IO ()
connectTo_V1 sn tracers versionData application localAddr remoteAddr =
    connectTo
      sn
      tracers
      (simpleSingletonVersions
          NodeToNodeV_1
          versionData
          (DictVersion nodeToNodeCodecCBORTerm)
          application)
      localAddr
      remoteAddr

-- | A specialised version of @'Ouroboros.Network.Socket.withServerNode'@.
-- It forks a thread which runs an accept loop (server thread):
--
-- * when the server thread throws an exception the main thread rethrows
--   it (by 'Async.wait')
-- * when an async exception is thrown to kill the main thread the server thread
--   will be cancelled as well (by 'withAsync')
--
withServer
  :: ( HasResponder appType ~ True )
  => SocketSnocket
  -> NetworkServerTracers Socket.SockAddr NodeToNodeVersion
  -> NetworkMutableState Socket.SockAddr
  -> Socket.SockAddr
  -> Versions NodeToNodeVersion DictVersion
              (ConnectionId Socket.SockAddr ->
                 OuroborosApplication appType BL.ByteString IO a b)
  -> ErrorPolicies
  -> IO Void
withServer sn tracers networkState addr versions errPolicies =
  withServerNode
    sn
    tracers
    networkState
    addr
    cborTermVersionDataCodec
    (\(DictVersion _) -> acceptableVersion)
    (fmap (SomeResponderApplication .) versions)
    errPolicies
    (\_ async -> Async.wait async)


-- | Like 'withServer' but specific to 'NodeToNodeV_1'.
--
withServer_V1
  :: ( HasResponder appType ~ True )
  => SocketSnocket
  -> NetworkServerTracers Socket.SockAddr NodeToNodeVersion
  -> NetworkMutableState Socket.SockAddr
  -> Socket.SockAddr
  -> NodeToNodeVersionData
  -> (ConnectionId Socket.SockAddr ->
        OuroborosApplication appType BL.ByteString IO x y)
  -> ErrorPolicies
  -> IO Void
withServer_V1 sn tracers networkState addr versionData application =
    withServer
      sn tracers networkState addr
      (simpleSingletonVersions
          NodeToNodeV_1
          versionData
          (DictVersion nodeToNodeCodecCBORTerm)
          application)


-- | 'ipSubscriptionWorker' which starts given application versions on each
-- established connection.
--
ipSubscriptionWorker
    :: forall appType x y.
       ( HasInitiator appType ~ True )
    => SocketSnocket
    -> NetworkIPSubscriptionTracers Socket.SockAddr NodeToNodeVersion
    -> NetworkMutableState Socket.SockAddr
    -> IPSubscriptionParams ()
    -> Versions
        NodeToNodeVersion
        DictVersion
        (ConnectionId Socket.SockAddr ->
           OuroborosApplication appType BL.ByteString IO x y)
    -> IO Void
ipSubscriptionWorker
  sn
  NetworkSubscriptionTracers
    { nsSubscriptionTracer
    , nsMuxTracer
    , nsHandshakeTracer
    , nsErrorPolicyTracer
    }
  networkState
  subscriptionParams
  versions
    = Subscription.ipSubscriptionWorker
        sn
        nsSubscriptionTracer
        nsErrorPolicyTracer
        networkState
        subscriptionParams
        (connectToNode'
          sn
          cborTermVersionDataCodec
          (NetworkConnectTracers nsMuxTracer nsHandshakeTracer)
          versions)


-- | Like 'ipSubscriptionWorker' but specific to 'NodeToNodeV_1'.
--
ipSubscriptionWorker_V1
    :: forall appType x y.
       ( HasInitiator appType ~ True )
    => SocketSnocket
    -> NetworkIPSubscriptionTracers Socket.SockAddr NodeToNodeVersion
    -> NetworkMutableState Socket.SockAddr
    -> IPSubscriptionParams ()
    -> NodeToNodeVersionData
    -> (ConnectionId Socket.SockAddr ->
          OuroborosApplication appType BL.ByteString IO x y)
    -> IO Void
ipSubscriptionWorker_V1
  sn
  tracers
  networkState
  subscriptionParams
  versionData
  application
    = ipSubscriptionWorker
        sn
        tracers
        networkState
        subscriptionParams
        (simpleSingletonVersions
          NodeToNodeV_1
          versionData
          (DictVersion nodeToNodeCodecCBORTerm)
          application)


-- | 'dnsSubscriptionWorker' which starts given application versions on each
-- established connection.
--
dnsSubscriptionWorker
    :: forall appType x y.
       ( HasInitiator appType ~ True )
    => SocketSnocket
    -> NetworkDNSSubscriptionTracers NodeToNodeVersion Socket.SockAddr
    -> NetworkMutableState Socket.SockAddr
    -> DnsSubscriptionParams ()
    -> Versions
        NodeToNodeVersion
        DictVersion
        (ConnectionId Socket.SockAddr ->
           OuroborosApplication appType BL.ByteString IO x y)
    -> IO Void
dnsSubscriptionWorker
  sn
  NetworkDNSSubscriptionTracers
    { ndstSubscriptionTracer
    , ndstDnsTracer
    , ndstMuxTracer
    , ndstHandshakeTracer
    , ndstErrorPolicyTracer
    }
  networkState
  subscriptionParams
  versions =
    Subscription.dnsSubscriptionWorker
      sn
      ndstSubscriptionTracer
      ndstDnsTracer
      ndstErrorPolicyTracer
      networkState
      subscriptionParams
      (connectToNode'
        sn
        cborTermVersionDataCodec
        (NetworkConnectTracers ndstMuxTracer ndstHandshakeTracer)
        versions)


-- | Like 'dnsSubscriptionWorker' but specific to 'NodeToNodeV_1'.
--
dnsSubscriptionWorker_V1
    :: forall appType x y.
       ( HasInitiator appType ~ True )
    => SocketSnocket
    -> NetworkDNSSubscriptionTracers NodeToNodeVersion Socket.SockAddr
    -> NetworkMutableState Socket.SockAddr
    -> DnsSubscriptionParams ()
    -> NodeToNodeVersionData
    -> (ConnectionId Socket.SockAddr ->
          OuroborosApplication appType BL.ByteString IO x y)
    -> IO Void
dnsSubscriptionWorker_V1
  sn
  tracers
  networkState
  subscriptionParams
  versionData
  application =
     dnsSubscriptionWorker
      sn
      tracers
      networkState
      subscriptionParams
      (simpleSingletonVersions
          NodeToNodeV_1
          versionData
          (DictVersion nodeToNodeCodecCBORTerm)
          application)

-- | A minimal error policy for remote peers, which only handles exceptions
-- raised by `ouroboros-network`.
--
remoteNetworkErrorPolicy :: ErrorPolicies
remoteNetworkErrorPolicy = ErrorPolicies {
      epAppErrorPolicies = [
          -- Handshake client protocol error: we either did not recognise received
          -- version or we refused it.  This is only for outbound connections,
          -- thus we suspend the consumer.
          ErrorPolicy
            $ \(_ :: HandshakeClientProtocolError NodeToNodeVersion)
                  -> Just misconfiguredPeer

          -- exception thrown by `runPeerWithLimits`
        , ErrorPolicy
            $ \(_ :: ProtocolLimitFailure)
                   -> Just theyBuggyOrEvil

          -- deserialisation failure; this means that the remote peer is either
          -- buggy, adversarial, or the connection return garbage.  In the last
          -- case it's also good to shutdown both the consumer and the
          -- producer, as it's likely that the other side of the connection
          -- will return grabage as well.
        , ErrorPolicy
            $ \(_ :: DeserialiseFailure)
                  -> Just theyBuggyOrEvil

          -- the connection was unexpectedly closed, we suspend the peer for
          -- a 'shortDelay'
        , ErrorPolicy
            $ \(e :: MuxError)
                  -> case errorType e of
                        MuxUnknownMiniProtocol  -> Just theyBuggyOrEvil
                        MuxDecodeError          -> Just theyBuggyOrEvil
                        MuxIngressQueueOverRun  -> Just theyBuggyOrEvil
                        MuxInitiatorOnly        -> Just theyBuggyOrEvil

                        -- in case of bearer closed / or IOException we suspend
                        -- the peer for a short time
                        --
                        -- TODO: an exponential backoff would be nicer than a fixed 20s
                        -- TODO: right now we cannot suspend just the
                        -- 'responder'.  If a 'responder' throws 'MuxError' we
                        -- might not want to shutdown the consumer (which is
                        -- using different connection), as we do below:
                        MuxBearerClosed         -> Just (SuspendPeer shortDelay shortDelay)
                        MuxIOException{}        -> Just (SuspendPeer shortDelay shortDelay)

          -- Error policy for TxSubmission protocol: outbound side (client role)
        , ErrorPolicy
            $ \(_ :: TxOutbound.TxSubmissionProtocolError)
                  -> Just theyBuggyOrEvil

          -- Error policy for TxSubmission protocol: inbound side (server role)
        , ErrorPolicy
            $ \(_ :: TxInbound.TxSubmissionProtocolError)
                  -> Just theyBuggyOrEvil

          -- Error policy for BlockFetch protocol: consumer side (client role)
        , ErrorPolicy
            $ \(_ :: BlockFetchProtocolFailure)
                  -> Just theyBuggyOrEvil
        ],

      -- Exception raised during connect; suspend connecting to that peer for
      -- a 'shortDelay'
      epConErrorPolicies = [
          ErrorPolicy $ \(_ :: IOException) -> Just $
            SuspendConsumer shortDelay
        ]
    }
  where
    theyBuggyOrEvil :: SuspendDecision DiffTime
    theyBuggyOrEvil = SuspendPeer defaultDelay defaultDelay

    misconfiguredPeer :: SuspendDecision DiffTime
    misconfiguredPeer = SuspendConsumer defaultDelay

    defaultDelay :: DiffTime
    defaultDelay = 200 -- seconds

    shortDelay :: DiffTime
    shortDelay = 20 -- seconds

-- | Error policy for local clients.  This is equivalent to
-- 'nullErrorPolicies', but explicit in the errors which can be catched.
--
-- We are very permissive here, and very strict in the
-- `NodeToClient.networkErrorPolicy`.  After any failure the client will be
-- killed and not penalised by this policy.  This allows to restart the local
-- client without a delay.
--
localNetworkErrorPolicy :: ErrorPolicies
localNetworkErrorPolicy = ErrorPolicies {
      epAppErrorPolicies = [
          -- exception thrown by `runPeerWithLimits`
          ErrorPolicy
            $ \(_ :: ProtocolLimitFailure)
                  -> Nothing

          -- deserialisation failure
        , ErrorPolicy
            $ \(_ :: DeserialiseFailure) -> Nothing

          -- the connection was unexpectedly closed, we suspend the peer for
          -- a 'shortDelay'
        , ErrorPolicy
          $ \(_ :: MuxError) -> Nothing
        ],

      -- The node never connects to a local client
      epConErrorPolicies = []
    }

type RemoteConnectionId = ConnectionId Socket.SockAddr
