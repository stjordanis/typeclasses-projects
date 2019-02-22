{-# OPTIONS_GHC -Wall #-}

{-# LANGUAGE LambdaCase, DeriveFunctor, ScopedTypeVariables, TypeApplications #-}

module Main (main) where

-- base
import qualified Control.Concurrent as Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Data.Fixed
import Numeric.Natural

-- cairo
import qualified Graphics.Rendering.Cairo as Cairo

-- gtk3
import qualified Graphics.UI.Gtk as Gtk
import Graphics.UI.Gtk (AttrOp ((:=)))

-- linear
import Linear.V2

-- pango
import qualified Graphics.Rendering.Pango as Pango

-- stm
import qualified Control.Concurrent.STM as STM

-- time
import qualified Data.Time as Time

-- unix
import qualified System.Posix.Signals as Signals

data DisplayTime =
    DisplayTime
        { displayHour :: Natural
        , displayMinute :: Natural
        , displaySecond :: Natural
        }
    deriving Eq

twoDigits :: Natural -> String
twoDigits x =
    case (show @Natural x) of
        [a]    -> ['0', a]
        [a, b] -> [a, b]
        _      -> "??"

showDisplayTime :: DisplayTime -> String
showDisplayTime (DisplayTime x y z) =
    twoDigits x <> ":" <>
    twoDigits y <> ":" <>
    twoDigits z

main :: IO ()
main = Concurrent.runInBoundThread $
  do
    quitOnInterrupt
    _ <- Gtk.initGUI

    timeVar <- STM.atomically (STM.newTVar Nothing)

    drawingArea :: Gtk.DrawingArea <- Gtk.drawingAreaNew
    Gtk.set drawingArea
      [ Gtk.widgetWidthRequest := 300
      , Gtk.widgetHeightRequest := 100
      ]
    _ <- Gtk.on drawingArea Gtk.draw (render drawingArea timeVar)

    frame <- Gtk.frameNew
    Gtk.set frame
      [ Gtk.containerChild := drawingArea
      , Gtk.frameLabel := "What time is it"
      , Gtk.frameLabelXAlign := 0.5
      , Gtk.frameLabelYAlign := 1
      , Gtk.widgetMarginTop := 20
      , Gtk.widgetMarginRight := 20
      , Gtk.widgetMarginBottom := 20
      , Gtk.widgetMarginLeft := 20
      ]

    window :: Gtk.Window <- Gtk.windowNew
    Gtk.set window
      [ Gtk.windowTitle := "Clock"
      , Gtk.containerChild := frame
      , Gtk.windowDefaultWidth := 500
      , Gtk.windowDefaultHeight := 250
      ]

    quitOnWindowClose window
    Gtk.widgetShowAll window

    runUntilQuit (runClock timeVar)
    runUntilQuit (watchClock timeVar drawingArea)

    Gtk.mainGUI

runUntilQuit :: IO a -> IO ()
runUntilQuit x =
  do
    _threadId <- Concurrent.forkFinally x (\_ -> Gtk.mainQuit)
    return ()

render
    :: Gtk.DrawingArea
    -> STM.TVar (Maybe DisplayTime)
    -> Cairo.Render ()

render drawingArea timeVar =
  do
    renderBackground
    renderText drawingArea timeVar

renderBackground :: Cairo.Render ()
renderBackground =
  do
    Cairo.setSourceRGB 1 0.9 1
    Cairo.paint

renderText
    :: Gtk.DrawingArea
    -> STM.TVar (Maybe DisplayTime)
    -> Cairo.Render ()

renderText drawingArea timeVar =
  do
    displayTimeMaybe <- liftIO (STM.atomically (STM.readTVar timeVar))

    let
        text =
            case displayTimeMaybe of
                Nothing -> ""
                Just time -> showDisplayTime time

    layout <- Pango.createLayout text

    liftIO $
      do
        fd <- Pango.fontDescriptionNew
        Pango.fontDescriptionSetFamily fd "Fira Mono"
        Pango.fontDescriptionSetSize fd 40
        Pango.layoutSetFontDescription layout (Just fd)

    Cairo.setSourceRGB 0.2 0.1 0.2
    showPangoCenter drawingArea layout

showPangoCenter :: Gtk.DrawingArea -> Gtk.PangoLayout -> Cairo.Render ()
showPangoCenter drawingArea layout =
  do
    clipCenter <- getClipCenter
    textCenter <- getTextCenter
    let (V2 x y) = clipCenter - textCenter
    Cairo.moveTo x y
    Pango.showLayout layout
  where
    getClipSize :: Cairo.Render (V2 Int) =
      do
        Gtk.Rectangle _x _y w h <- liftIO (Gtk.widgetGetClip drawingArea)
        return (V2 w h)

    getClipCenter :: Cairo.Render (V2 Double) =
      do
        size <- getClipSize
        return ((realToFrac <$> size) / 2)

    getTextCenter :: Cairo.Render (V2 Double) =
      do
        (_, Gtk.PangoRectangle x y w h) <-
            liftIO (Pango.layoutGetExtents layout)
        return (V2 x y + (V2 w h / 2))

quitOnWindowClose :: Gtk.Window -> IO ()
quitOnWindowClose window =
  do
    _connectId <- Gtk.on window Gtk.deleteEvent action
    return ()
  where
    action =
      do
        liftIO Gtk.mainQuit
        return False

quitOnInterrupt :: IO ()
quitOnInterrupt =
  do
    _oldHandler <- Signals.installHandler Signals.sigINT quitHandler Nothing
    return ()
  where
    quitHandler :: Signals.Handler
    quitHandler = Signals.Catch (liftIO (Gtk.postGUIAsync Gtk.mainQuit))

-- | @'runClock' t@ is an IO action that runs forever, keeping the value of @t@
-- equal to the current time.
runClock :: STM.TVar (Maybe DisplayTime) -> IO ()
runClock timeVar =
  forever $
    do
      time <- getLocalTimeOfDay
      let (displayTime, remainderSeconds) = interpretTime time
      liftIO (STM.atomically (STM.writeTVar timeVar (Just displayTime)))
      threadDelaySeconds (1 - remainderSeconds)

-- | Get the current time of day in the system time zone.
getLocalTimeOfDay :: IO Time.TimeOfDay
getLocalTimeOfDay =
  do
    tz :: Time.TimeZone <- Time.getCurrentTimeZone
    utc :: Time.UTCTime <- Time.getCurrentTime
    return (Time.localTimeOfDay (Time.utcToLocalTime tz utc))

-- | Pick out the relevant aspects of the time that we care about.
interpretTime :: Time.TimeOfDay -> (DisplayTime, Pico)
interpretTime x = (displayTime, remainderSeconds)
    where
      displayTime =
          DisplayTime
              { displayHour = fromIntegral (Time.todHour x)
              , displayMinute = fromIntegral (Time.todMin x)
              , displaySecond = fromIntegral clockSeconds
              }

      (clockSeconds :: Int, remainderSeconds :: Pico) =
          properFraction (Time.todSec x)

-- | @'watchClock' t w@ is an IO action that runs forever. Each time the value
-- of @t@ changes, it invalidates the drawing area @w@, thus forcing it to
-- redraw and update the display.
watchClock :: Gtk.WidgetClass w
    => STM.TVar (Maybe DisplayTime) -> w -> IO ()
watchClock timeVar drawingArea =
    go Nothing
  where
    go :: Maybe DisplayTime -> IO ()
    go s =
      do
        s' <- STM.atomically (mfilter (s /=) (STM.readTVar timeVar))
        Gtk.postGUIAsync (Gtk.widgetQueueDraw drawingArea)
        go s'

-- | Block for some fixed number of seconds.
threadDelaySeconds :: RealFrac n => n -> IO ()
threadDelaySeconds =
    Concurrent.threadDelay . round . (* million)

-- | One million = 10^6.
million :: Num n => n
million =
    10 ^ (6 :: Int)
