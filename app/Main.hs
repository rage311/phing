{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Concurrent
import Control.Monad
import Data.Binary
import Data.Bits
import Data.IORef
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List
import Data.Time
import Network.Socket
import Network.Socket.ByteString (recvFrom, sendAll)
import Text.Printf

import ICMP


defaultTimeoutus :: Timeout
defaultTimeoutus = 4000 * 1000

defaultTimeoutMs :: Timeout
defaultTimeoutMs = 4000

data Message
  = MsgPingSent (Word32, UTCTime)
  | MsgPingReceived (Word32, UTCTime, SockAddr)

type RefId    = Word32
type SentTime = UTCTime
type RecvTime = UTCTime
type Timeout  = Int

data PingResult
  = Received
  | TimedOut
  deriving (Eq, Show)

data PingRef = PingRef
  { refId      :: Word32 -- ident << 16 | seqNum
  -- , packet  :: PingPacket
  , sentTime   :: UTCTime
  , resultTime :: UTCTime
  , result     :: PingResult
  }
  deriving (Eq, Show)

data PingSent = PingSent
  { sentRefId       :: RefId
  , time            :: SentTime
  , timeoutThreadId :: ThreadId
  }
  deriving (Eq, Show)

-- TODO:
-- write custom show impl to pretty print
--   + truncate decimal precision on Doubles
data PingStats = PingStats
  { countSent       :: Int
  , countRecv       :: Int
  -- , countTotalTxRx  :: Int
  , countTimeout    :: Int
  , countSuccess    :: Int
  , pctSuccess      :: Double
  , avgRoundTrip    :: Double
  , minRoundTrip    :: Double
  , maxRoundTrip    :: Double
  , stdDevRoundTrip :: Double
  }
  deriving (Eq, Show)

initialStats :: PingStats
initialStats = PingStats
  { countSent       = 0
  , countRecv       = 0
  , countTimeout    = 0
  , countSuccess    = 0
  , pctSuccess      = 0.0
  , avgRoundTrip    = 0.0
  , minRoundTrip    = fromIntegral defaultTimeoutMs
  , maxRoundTrip    = 0.0
  , stdDevRoundTrip = 0.0
  }

-- attempt at "incrementing" stats
-- -- TODO: IN PROGRESS:
-- -- does countSent get accounted for?
-- calcStat :: PingStats -> PingRef -> PingStats
-- calcStat
--   acc@(PingStats
--     { countSent       = countSent'
--     , countRecv       = countRecv'
--     , countTimeout    = countTimeout'
--     , countSuccess    = countSuccess'
--     , pctSuccess      = pctSuccess'
--     , avgRoundTrip    = avgRoundTrip'
--     , minRoundTrip    = minRoundTrip'
--     , maxRoundTrip    = maxRoundTrip'
--     , stdDevRoundTrip = stdDevRoundTrip'
--     })
--   ping@(PingRef { .. }) =
--   case result of
--     Received ->
--       let
--         lastStats = acc
--         pingDiff         = pingDiffMs ping
--         totalRoundTripMs = avgRoundTrip' * (fromIntegral countSuccess' - 1)
--       in
--         acc
--           { countRecv    = countRecv lastStats + 1
--           , countSuccess = countSuccess lastStats + 1
--           , pctSuccess   = fromIntegral countSuccess' / fromIntegral countTotal * 100.00
--           , avgRoundTrip = (totalRoundTripMs + pingDiff) / fromIntegral countSuccess'
--           , minRoundTrip = min minRoundTrip' pingDiff
--           , maxRoundTrip = max maxRoundTrip' pingDiff
--           -- TODO: stdDevRoundTrip
--           }
--     TimedOut -> acc
--       { countTimeout = countTimeout' + 1
--       , pctSuccess     = fromIntegral countSuccess' / fromIntegral countTotal * 100.00
--       }
--   where
--     countTotal = countRecv' + countSent' + countTimeout'
--     increment x y = x + y

-- TODO: calc only for last n packets?
calcStats :: [PingRef] -> [PingSent] -> PingStats
calcStats [] [] = initialStats
calcStats [] _ = initialStats
calcStats refs sent = do
  -- refs' <- readIORef refs
  -- sent' <- readIORef sent
  let countSent = length refs + length sent

  -- let stats' = stats { countSent = length refs + length sent }
  -- foldl calcStat stats' refs

  let successRefs  = filter (\x -> result x == Received) refs
  let countRecv    = length successRefs
  let pctSuccess   = 100.0 * (fromIntegral countRecv / fromIntegral countSent)
  let pingDiffs    = map pingDiffMs successRefs
  let avgRoundTrip = sum pingDiffs / fromIntegral (length successRefs)
  let minRoundTrip = minimum pingDiffs
  let maxRoundTrip = maximum pingDiffs

  initialStats
    { countSent
    , countRecv
    , pctSuccess
    , avgRoundTrip
    , minRoundTrip
    , maxRoundTrip
    -- TODO:
    -- , stdDevRoundTrip = undefined
    }

-- combines id and seqNum to form a unique refId
mkRefId :: Word16 -> Word16 -> Word32
mkRefId ident seqNum = fromIntegral ident .<<. 16 .|. fromIntegral seqNum

pingDiffMs :: PingRef -> Double
pingDiffMs (PingRef { sentTime, resultTime }) = 1000.0 *
  (realToFrac $ nominalDiffTimeToSeconds (diffUTCTime resultTime sentTime) :: Double)

sendPing :: Socket -> Chan Message -> Word16 -> Word16 -> BS.ByteString -> IO ()
sendPing sock chan ident seqNum payload = do
  let ping = mkChecksum $
        defaultPingRequest
          { ident
          , seqNum
          , payload
          }

  sendAll sock $ BS.toStrict $ encode ping
  getCurrentTime >>= \now ->
    writeChan chan $ MsgPingSent (mkRefId ident seqNum, now)

pingListen :: Socket -> Chan Message -> IO ()
pingListen sock chan = forever $ do
  (recvData, sockAddr) <- recvFrom sock 1024
  --print recvData
  recvTime <- getCurrentTime

  -- skip IP header
  let icmp = drop 20 $ BS.unpack recvData
  let ping = decode (BSL.pack icmp) :: PingPacket
  --print $ "received ping: " <> show ping
  let refId' = mkRefId (ident ping) (seqNum ping)
  writeChan chan $ MsgPingReceived (refId', recvTime, sockAddr)
  putStrLn ""

pingMaster :: Chan Message -> IO ()
pingMaster chan = do
  -- let stats = initialStats
  -- TODO: wrapper around each? or just refs?
  -- e.g. addNewRef refs newPingRef -- return the new value?
  stats <- newIORef initialStats :: IO (IORef PingStats)
  refs  <- newIORef [] :: IO (IORef [PingRef])
  sent  <- newIORef [] :: IO (IORef [PingSent])

  forever $ do
    readChan chan >>= \case
      (MsgPingSent (refId', sentTime)) -> do
        putStrLn $ "Sent: " <> show refId'

        -- start timeout timer
        timeoutThreadId <- forkIO $ do
          threadDelay defaultTimeoutus
          putStrLn $ show refId' <> " timed out"
          getCurrentTime >>= \now ->
            modifyIORef refs $ \refs' ->
              PingRef refId' sentTime now TimedOut : refs'
        modifyIORef sent $ \sent' ->
          sent' <> [PingSent refId' sentTime timeoutThreadId]
        return ()

      (MsgPingReceived (refId', recvTime', sockAddr)) -> do
        -- putStrLn $ "Recv: refId " <> show refId' <> " @ " <> show recvTime'
        putStrLn $ "Received reply for refId "
          <> show refId'
          <> " from: " <> show sockAddr

        (matches@(match:_ms), noMatch) <- readIORef sent >>= \sent' ->
          return $ partition (\(PingSent refId _ _) -> refId == refId') sent'
        if null matches then do
           putStrLn $ "No match for seqNum: " <> show refId'
        else do
          let (PingSent sentId sentTime timeoutThreadId) = match
          killThread timeoutThreadId
          writeIORef sent noMatch

          let pingRef = PingRef sentId sentTime recvTime' Received
          putStrLn $ printf "%.1f ms\n" $ pingDiffMs pingRef

          -- update refs
          refs' <- readIORef refs
          let newRefs = pingRef : refs'
          writeIORef refs newRefs

          -- update stats
          sent' <- readIORef sent
          let newStats = calcStats newRefs sent'
          print newStats
          writeIORef stats newStats

main :: IO ()
main = do
  let intervalSec = 1000 * 5000
  let ident       = 666
  addr <-
    head <$> getAddrInfo
      (Just defaultHints
          { addrFlags      = [AI_ADDRCONFIG]
          , addrSocketType = Raw
          , addrProtocol   = 1
      })
      (Just "8.8.8.8")
      Nothing
  print addr

  chan <- newChan :: IO (Chan Message)

  sock <- openSocket addr
  print sock
  print $ addrAddress addr
  connect sock (addrAddress addr)

  let pings =
        map (\seqNum -> do
          let payload = "your mom goes to college" :: BS.ByteString
          putStrLn $ "Sending " <> show (BS.length payload) <> " bytes to " <> show addr
          sendPing sock chan ident seqNum payload
          threadDelay intervalSec
        ) [0..]

  threadsDone <- newEmptyMVar
  _listenThreadId <- forkFinally
    (pingListen sock chan)
    (\_ -> putMVar threadsDone myThreadId)
  _masterThreadId <- forkIO $ pingMaster chan

  forever $ sequence_ pings
