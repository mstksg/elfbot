{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE QuasiQuotes               #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeInType                #-}
{-# LANGUAGE ViewPatterns              #-}

module Santabot (
    puzzleLink
  , puzzleThread
  , nextPuzzle
  , challengeCountdown
  , eventCountdown
  , boardCapped
  , acknowledgeTick
  , santaPhrases
  , addSantaPhrase
  , validYears
  ) where

import           Advent
import           Advent.API                as Advent
import           Advent.Cache
import           Advent.Reddit
import           Advent.Types
import           Conduit
import           Control.Monad
import           Control.Monad.Trans.Maybe
import           Data.Bifunctor
import           Data.Char
import           Data.Finite
import           Data.Foldable
import           Data.Functor
import           Data.Map                  (Map)
import           Data.Maybe
import           Data.Set                  (Set)
import           Data.Text                 (Text)
import           Data.Time                 as Time
import           Santabot.Bot
import           Servant.API
import           Servant.Client.Core
import           Servant.Links
import           System.Directory
import           System.FilePath
import           System.Random
import           Text.Megaparsec
import           Text.Read                 (readMaybe)
import qualified Data.Duration             as DD
import qualified Data.Map                  as M
import qualified Data.Set                  as S
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as T
import qualified Data.Yaml                 as Y
import qualified Language.Haskell.Printf   as P
import qualified Numeric.Interval          as I

santaPhrases :: Set Text
santaPhrases = S.fromList
    [ "Ho ho ho!"
    , "Deck the channels!"
    , "Joy to the freenode!"
    , "I just elfed myself!"
    , "Have you been naughty or nice?"
    , "Won't you guide my debugger tonight?"
    , "Calling all reindeer!"
    , "Run that checksum twice!"
    , "Yule be in for a treat!"
    , "A round of Santa-plause, please."
    , "Let it snow!"
    , "Jingle \\a, jingle all the way!"
    , "Hoooo ho ho!"
    , "Do you hear what I hear?"
    , "Who's ready for Christmas cheer?"
    , "Get out the hot cocoa!"
    , "I'm dreaming of a bug-free Christmas!"
    , "My list is formally verified twice!"
    , "Now Dasher, now Dancer!"
    , "It's the most wonderful time of the year!"
    , "Francisco!"
    , "Son of a nutcracker!"
    , "Has anyone seen my sleigh?"
    , "Sharpen up your elfcode!"
    , "Sing loud for all to hear!"
    , "Time to spread some Christmas cheer!"
    , "It's silly, but I believe!"
    , "Yipee ki-yay, coders!"
    , "Welcome to the party, pal."
    , "I'll be $HOME for Christmas!"
    , "Hark!"
    , "Hooo ho ho!"
    , "Ho ho hoooo!"
    , "Rest ye merry CPUs!"
    , "Code yourself a merry little Christmas!"
    , "Must've been some magic in that old compiler!"
    ]


puzzleLink :: MonadIO m => Command m
puzzleLink = C
    { cName  = "link"
    , cHelp  = "Get the link to a given puzzle (!link 23, !link 2017 16).  If bad day or year given, just returns most recent match."
    , cParse = askLink
    , cResp  = pure . T.pack . uncurry displayLink
    }

puzzleThread :: MonadIO m => Command m
puzzleThread = C
    { cName  = "thread"
    , cHelp  = "Get the link to a given puzzle's reddit discussion thread (!thread 23, !thread 2017 16).  If bad day or year given, just returns most recent match."
    , cParse = askLink
    , cResp  = \(y,d) -> liftIO $
        getPostLink y d <&> \case
          Nothing -> "Thread not available, sorry!"
          Just u  -> T.pack $
            [P.s|[%d Day %d] %s|] y (dayInt d) u
    }

-- TODO: make this just return the current day's puzzle, if it exists.
askLink
    :: MonadIO m
    => Message
    -> m (Either Text (Integer, Advent.Day))
askLink M{..} = do
    allP <- liftIO allPuzzles
    case listToMaybe (mapMaybe mkDay w) of
      Nothing  -> do
        (y, m, d) <- toGregorian . localDay <$> liftIO aocTime
        case mkDay (fromIntegral d) of
          Just dd
            | m == 12
            , dd `S.member` fold (M.lookup y allP)
            -> pure $ Right (y, dd)
          _ -> pure $ Left "No valid day found."
      Just day -> pure . Right $
        let hasDays  = M.keysSet . M.filter (S.member day) $ allP
            givenYear = find (`S.member` hasDays) w
            trueYear  = case givenYear of
              Just k | k `S.member` hasDays -> k
              _                             -> S.findMax hasDays
        in  (trueYear, day)
  where
    w = mapMaybe (readMaybe . T.unpack) . T.words . T.map clear $ mBody
    clear c
      | isDigit c = c
      | otherwise = ' '

allPuzzles :: IO (Map Integer (Set Advent.Day))
allPuzzles = do
    vy <- validYears
    sequence . flip M.fromSet vy $ \y -> S.fromList <$>
      filterM (challengeReleased y) (Day <$> finites)

nextPuzzle :: MonadIO m => Command m
nextPuzzle = simpleCommand "next" "Display the time until the next puzzle release." $ do
    t <- liftIO aocTime
    let (y, d)    = nextDay (localDay t)
        nextTime  = LocalTime (fromGregorian y 12 (fromIntegral (dayInt d))) midnight
        dur       = realToFrac $ nextTime `diffLocalTime` t
        durString = T.unpack . T.strip . T.pack
                  $ DD.humanReadableDuration dur
    addSantaPhrase . T.pack $
      [P.s|Next puzzle (%d Day %d) will be released in %s.|]
        y
        (dayInt d)
        durString
  where
    nextDay (toGregorian->(y,m,d))
      | m < 12    = (y, minBound)
      | otherwise = case mkDay (fromIntegral d) of
          Nothing -> (y + 1, minBound)
          Just d' -> (y    , d'      )

data ChallengeEvent = CEHour
                    | CETenMin
                    | CEMinute
                    | CEStart
  deriving Show

challengeCountdown :: MonadIO m => Alert m
challengeCountdown = A
    { aTrigger = pure . challengeEvent
    , aResp    = traverse (addSantaPhrase . T.pack)
               . uncurry displayCE
    }
  where
    challengeEvent i = do
        guard $ (mm == 12) || (mm == 11 && dd == 30)
        first (,yy) <$> do
          listToMaybe . mapMaybe (uncurry pick) $ evts
      where
        d = localDay $ I.sup i
        (yy ,mm, dd ) = toGregorian d
        (_  ,_  ,dd') = toGregorian (succ d)
        evts =
          [ (LocalTime d midnight           , (,CEStart ) <$> mkDay (fromIntegral dd ))
          , (LocalTime d (TimeOfDay 23 0  0), (,CEHour  ) <$> mkDay (fromIntegral dd'))
          , (LocalTime d (TimeOfDay 23 50 0), (,CETenMin) <$> mkDay (fromIntegral dd'))
          , (LocalTime d (TimeOfDay 23 59 0), (,CEMinute) <$> mkDay (fromIntegral dd'))
          ]
        pick t e = guard (t `I.member` i) *> e
    displayCE (d, yr) = \case
      CEHour   -> (False, [P.s|One hour until Day %d challenge!|]    (dayInt d)                   )
      CETenMin -> (False, [P.s|Ten minutes until Day %d challenge!|] (dayInt d)                   )
      CEMinute -> (False, [P.s|One minute until Day %d challenge!|]  (dayInt d)                   )
      CEStart  -> (True , [P.s|Day %d challenge now online at %s !|] (dayInt d) (displayLink yr d))

eventCountdown :: MonadIO m => Alert m
eventCountdown = A
    { aTrigger = pure . countdownEvent
    , aResp    = fmap (True,) . addSantaPhrase . T.pack . uncurry displayCE
    }
  where
    countdownEvent i = do
        guard $ LocalTime d midnight `I.member` i
        guard $ m < 12
        (,y) <$> daysLeft
      where
        d        = localDay $ I.sup i
        (y,m,_)  = toGregorian d
        daysLeft = packFinite @14 $ (fromGregorian y 12 1 `diffDays` d) - 1

    displayCE d = [P.s|%d day%s left until Advent of Code %d!|] n suff
      where
        n = getFinite d + 1
        suff | n == 1    = "" :: String
             | otherwise = "s"

data CapState = CSEmpty     -- ^ file not even made yet
              | CSNeg       -- ^ file made but it is False
              | CSPos       -- ^ file made and it is True

boardCapped :: MonadIO m => Alert m
boardCapped = A
    { aTrigger = risingEdge
    , aResp    = fmap (True,) . addSantaPhrase <=< uncurry sendEdge
    }
  where
    logDir = "cache/capped"
    risingEdge (I.sup->i) = runMaybeT $ do
        liftIO $ createDirectoryIfMissing True logDir
        guard $ mm == 12
        d' <- maybe empty pure $ mkDay (fromIntegral dd)
        let logFP = logDir </> [P.s|%d-%02d|] yy (dayInt d') -<.> "yaml"
        liftIO (getCapState logFP) >>= \case
          CSPos   -> empty
          CSEmpty -> liftIO (Y.encodeFile logFP False) *> empty
          CSNeg   -> do
            u  <- MaybeT . liftIO $ getPostLink yy d'
            guard =<< liftIO (checkUncapped u)
            pure (u, (logFP, (yy, d')))
      where
        d          = localDay i
        (yy,mm,dd) = toGregorian d
    sendEdge linkUrl (logFP, (y, d)) = liftIO $ do
        Y.encodeFile logFP True
        lb <- runAoC (defaultAoCOpts y "") $ AoCDailyLeaderboard d
        let finalTime  = maximum . map dlbmTime . toList . dlbStar2 <$> lb
            timeString = formatTime defaultTimeLocale "at %H:%M:%S EST "
                       . utcToLocalTime (read "EST")
                     <$> finalTime
            timeString' = either (const "") id timeString
        pure . T.pack $
          [P.s|Leaderboard for Day %d is now capped %s(%s)!|]
            (dayInt d) timeString' linkUrl
      where
    getCapState l = readFileMaybe l <&> \case
      Nothing -> CSEmpty
      Just x  -> case Y.decodeEither' (T.encodeUtf8 x) of
        Left _      -> CSEmpty
        Right False -> CSNeg
        Right True  -> CSPos


acknowledgeTick :: Applicative m => Alert m
acknowledgeTick = A
    { aTrigger = pure . Just
    , aResp    = pure . (False,) . T.pack . show
    }

validYears :: IO (Set Integer)
validYears = do
    (y, mm, _) <- toGregorian . localDay <$> aocTime
    let y' | mm >= 11  = y
           | otherwise = y - 1
    pure $ S.fromList [2015 .. y']

displayLink :: Integer -> Advent.Day -> String
displayLink yr day = u
  where
    rp :<|> _ = allLinks adventAPI yr
    rd :<|> _ = rp day
    u = showBaseUrl $ aocBase { baseUrlPath = show (linkURI rd) }

addSantaPhrase :: MonadIO m => Text -> m Text
addSantaPhrase txt = liftIO $ do
    pick <- (`S.elemAt` santaPhrases)
        <$> randomRIO (0, S.size santaPhrases - 1)
    pure $ pick <> " " <> txt

