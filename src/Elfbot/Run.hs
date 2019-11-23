{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Elfbot.Run (
    launchIRC
  ) where

import           Control.Applicative
import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TBMQueue
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import           Data.Conduit hiding             (connect)
import           Data.Conduit.TQueue
import           Elfbot.Bot
import           Network.SimpleIRC
import           System.IO
import qualified Data.Conduit.Combinators        as C
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as T

-- | IRC configuration for simpleirc.  Specifies server, name,
-- channels, and the Privmsg handler.
ircConf :: [String] -> String -> MVar () -> TBMQueue Event -> IrcConfig
ircConf channels nick started eventQueue = (mkDefaultConfig "irc.freenode.org" nick)
      { cChannels = channels
      , cEvents   = [Privmsg onMessage, Disconnect onDisc, RawMsg begin]
      }
  where
    onMessage _ IrcMessage{..} = void . runMaybeT $ do
        room  <- T.unpack . T.decodeUtf8 <$> maybe empty pure mOrigin
        user  <- T.unpack . T.decodeUtf8 <$> maybe empty pure mNick
        lift . atomically . writeTBMQueue eventQueue . EMsg $
          M { mRoom = room
            , mUser = user
            , mBody = body
            }
      where
        body = T.decodeUtf8 mMsg
    onDisc _ = atomically $ closeTBMQueue eventQueue
    begin _ _ = void $ tryPutMVar started ()



-- | Begin the IRC process with stdout logging.
launchIRC
    :: [String]         -- ^ channels to join
    -> String           -- ^ nick
    -> Int              -- ^ tick delay (microseconds)
    -> Bot IO ()
    -> IO ()
launchIRC channels nick tick b = do
    eventQueue <- atomically $ newTBMQueue 1000000
    started    <- newEmptyMVar

    Right irc <- connect (ircConf channels nick started eventQueue) True True

    let sendResp R{..} = sendMsg irc (T.encodeUtf8 . T.pack $ rRoom)
                                     (T.encodeUtf8 rBody)

    _ <- forkIO $ do
      () <- takeMVar started
      forever $ do
        threadDelay tick
        t <- aocTime
        atomically $ writeTBMQueue eventQueue (ETick t)

    runConduit $ sourceTBMQueue eventQueue
              .| b
              .| C.iterM logResp
              .| C.mapM_ sendResp
              .| C.sinkNull

logResp :: Resp -> IO ()
logResp = hPrint stderr
