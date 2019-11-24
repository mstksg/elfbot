{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Santabot.Run (
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
import           Network.SimpleIRC               as IRC
import           Santabot.Bot
import qualified Data.Conduit.Combinators        as C
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as T
import qualified Data.Text.IO                    as T

-- | IRC configuration for simpleirc.  Specifies server, name,
-- channels, and the Privmsg handler.
ircConf
    :: [String]
    -> String
    -> Maybe String
    -> MVar ()
    -> TBMQueue Event
    -> IrcConfig
ircConf channels nick pwd started eventQueue = (mkDefaultConfig "irc.freenode.org" nick)
      { cChannels = channels
      , cPass     = pwd
      , cEvents   = [Privmsg onMessage, Disconnect onDisc, Notice begin]
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
    -> Maybe String     -- ^ password
    -> Int              -- ^ tick delay (microseconds)
    -> Bot IO ()
    -> IO ()
launchIRC channels nick pwd tick bot = do
    eventQueue <- atomically $ newTBMQueue 1000000
    started    <- newEmptyMVar

    Right irc <- connect (ircConf channels nick pwd started eventQueue) True True

    _ <- forkIO $ do
      () <- takeMVar started
      threadDelay 5000000
      forever $ do
        threadDelay tick
        t <- aocTime
        atomically $ writeTBMQueue eventQueue (ETick t)

    runConduit $ sourceTBMQueue eventQueue
              .| bot
              .| C.map respCommand
              .| C.iterM logResp
              .| C.mapM_ (sendCmd irc)
              .| C.sinkNull

logResp :: IRC.Command -> IO ()
logResp cmd = T.putStrLn $
    "[SENT] " <> T.decodeUtf8 (showCommand cmd)

respCommand :: Resp -> IRC.Command
respCommand R{..} = case rType of
    RTMessage -> MPrivmsg rm msg
    RTAction  -> MAction  rm msg
  where
    rm  = T.encodeUtf8 . T.pack $ rRoom
    msg = T.encodeUtf8 $ " " <> rBody