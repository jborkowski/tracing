{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-} -- For the MonadReader instance.

-- | This module is useful mostly for tracing backend implementors. If you are only interested in
-- adding tracing to an application, start at "Monitor.Tracing".
module Control.Monad.Trace (
  -- * Tracers
  Tracer(..), newTracer,
  runTraceT, runTraceT', TraceT,

  -- * Collected data
  -- | Tracers currently expose two pieces of data: completed spans and pending span count. Note
  -- that only sampled spans are eligible: spans which are 'Control.Monad.Trace.Class.neverSampled'
  -- appear in neither.

  -- ** Completed spans
  spanSamples, Sample(..), Tags, Logs,

  -- ** Pending spans
  pendingSpanCount,

  Scope(..),
  initScope,
  rootScope
) where

import Prelude hiding (span)

import Control.Monad.Trace.Class
import Control.Monad.Trace.Internal

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT(ReaderT), ask, asks, local, runReaderT)
import Control.Monad.Reader.Class (MonadReader)
import Control.Monad.Trans.Class (MonadTrans, lift)
import qualified Data.Aeson as JSON
import Data.Foldable (for_)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import UnliftIO (MonadUnliftIO, withRunInIO)
import UnliftIO.Exception (finally)
import UnliftIO.STM (TChan, TVar, atomically, modifyTVar', newTChanIO, newTVarIO, readTVar, writeTChan, writeTVar)

-- | A collection of span tags.
type Tags = Map Key JSON.Value

-- | A collection of span logs.
type Logs = [(POSIXTime, Key, JSON.Value)]

-- | A sampled span and its associated metadata.
data Sample = Sample
  { sampleSpan :: !Span
  -- ^ The sampled span.
  , sampleTags :: !Tags
  -- ^ Tags collected during this span.
  , sampleLogs :: !Logs
  -- ^ Logs collected during this span, sorted in chronological order.
  , sampleStart :: !POSIXTime
  -- ^ The time the span started at.
  , sampleDuration :: !NominalDiffTime
  -- ^ The span's duration.
  }

-- | A tracer is a producer of spans.
--
-- More specifically, a tracer:
--
-- * runs 'MonadTrace' actions via 'runTraceT',
-- * transparently collects their generated spans,
-- * and outputs them to a channel (available via 'spanSamples').
--
-- These samples can then be consumed independently, decoupling downstream span processing from
-- their production.
data Tracer = Tracer
  { tracerChannel :: TChan Sample
  , tracerPendingCount :: TVar Int
  }

-- | Creates a new 'Tracer'.
newTracer :: MonadIO m => m Tracer
newTracer = liftIO $ Tracer <$> newTChanIO <*> newTVarIO 0

-- | Returns the number of spans currently in flight (started but not yet completed).
pendingSpanCount :: Tracer -> TVar Int
pendingSpanCount = tracerPendingCount

-- | Returns all newly completed spans' samples. The samples become available in the same order they
-- are completed.
spanSamples :: Tracer -> TChan Sample
spanSamples = tracerChannel

data Scope = Scope
  { scopeTracer :: !Tracer
  , scopeSpan :: !(Maybe Span)
  , scopeTags :: !(Maybe (TVar Tags))
  , scopeLogs :: !(Maybe (TVar Logs))
  }

-- | A span generation monad.
newtype TraceT m a = TraceT { traceTReader :: ReaderT (Maybe Scope) m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans)

instance MonadReader r m => MonadReader r (TraceT m) where
  ask = lift ask
  local f (TraceT (ReaderT g)) = TraceT $ ReaderT $ \r -> local f $ g r

initScope
  :: MonadUnliftIO m
  => Scope             -- ^ parent scope
  -> Builder 
  -> m (m (Maybe Scope), m ()) -- ^ returns function to initialize child scope, and function to finish it
initScope parentScope bldr = do
  let
    mbParentSpn = scopeSpan parentScope
    mbParentCtx = spanContext <$> mbParentSpn
    mbTraceID = contextTraceID <$> mbParentCtx
  spanID <- maybe (liftIO randomSpanID) pure $ builderSpanID bldr
  traceID <- maybe (liftIO randomTraceID) pure $ builderTraceID bldr <|> mbTraceID
  sampling <- case builderSamplingPolicy bldr of
    Just policy -> liftIO policy
    Nothing -> pure $ fromMaybe Never (spanSamplingDecision <$> mbParentSpn)
  let
    baggages = fromMaybe Map.empty $ contextBaggages <$> mbParentCtx
    ctx = Context traceID spanID (builderBaggages bldr `Map.union` baggages)
    spn = Span (builderName bldr) ctx (builderReferences bldr) sampling
    tracer = scopeTracer parentScope
  if spanIsSampled spn
    then do
      tagsTV <- newTVarIO $ builderTags bldr
      logsTV <- newTVarIO []
      startTV <- newTVarIO Nothing -- To detect whether an exception happened during span setup.
      let
        scope = Scope tracer (Just spn) (Just tagsTV) (Just logsTV)
        run = do
          start <- liftIO $ getPOSIXTime
          atomically $ do
            writeTVar startTV (Just start)
            modifyTVar' (tracerPendingCount tracer) (+1)
          pure $ Just scope
        cleanup = do
          end <- liftIO $ getPOSIXTime
          atomically $ readTVar startTV >>= \case
            Nothing -> pure () -- The action was interrupted before the span was pending.
            Just start -> do
              modifyTVar' (tracerPendingCount tracer) (\n -> n - 1)
              tags <- readTVar tagsTV
              logs <- sortOn (\(t, k, _) -> (t, k)) <$> readTVar logsTV
              writeTChan (tracerChannel tracer) (Sample spn tags logs start (end - start))
      pure (run, cleanup)
    else
      pure (pure $ Just (Scope tracer (Just spn) Nothing Nothing), pure ())

instance MonadUnliftIO m => MonadTrace (TraceT m) where
  trace bldr (TraceT reader) = TraceT $ ask >>= \case
    Nothing -> reader
    Just parentScope -> do
      (start, cleanup) <- initScope parentScope bldr
      (do span <- start; local (const span) reader) `finally` cleanup

  activeSpan = TraceT $ asks (>>= scopeSpan)

  addSpanEntry key (TagValue val) = TraceT $ do
    mbTV <- asks (>>= scopeTags)
    for_ mbTV $ \tv -> atomically $ modifyTVar' tv $ Map.insert key val
  addSpanEntry key (LogValue val mbTime)  = TraceT $ do
    mbTV <- asks (>>= scopeLogs)
    for_ mbTV $ \tv -> do
      time <- maybe (liftIO getPOSIXTime) pure mbTime
      atomically $ modifyTVar' tv ((time, key, val) :)

instance MonadUnliftIO m => MonadUnliftIO (TraceT m) where
  withRunInIO inner = TraceT $ withRunInIO $ \run -> inner (run . traceTReader)

-- | Trace an action, sampling its generated spans. This method is thread-safe and can be used to
-- trace multiple actions concurrently.
--
-- Unless you are implementing a custom span publication backend, you should not need to call this
-- method explicitly. Instead, prefer to use the backend's functionality directly (e.g.
-- 'Monitor.Tracing.Zipkin.run' for Zipkin). To ease debugging in certain cases,
-- 'Monitor.Tracing.Local.collectSpanSamples' is also available.
--
-- See 'runTraceT'' for a variant which allows discarding spans.
runTraceT :: TraceT m a -> Tracer -> m a
runTraceT actn tracer = runTraceT' actn (Just tracer)

-- | Maybe trace an action. If the tracer is 'Nothing', no spans will be published.
runTraceT' :: TraceT m a -> Maybe Tracer -> m a
runTraceT' (TraceT reader) mbTracer =
  let scope = fmap rootScope mbTracer
  in runReaderT reader scope

rootScope :: Tracer -> Scope
rootScope tracer = Scope tracer Nothing Nothing Nothing
