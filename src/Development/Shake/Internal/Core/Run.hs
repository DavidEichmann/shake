{-# LANGUAGE RecordWildCards, NamedFieldPuns, ScopedTypeVariables, PatternGuards #-}
{-# LANGUAGE ConstraintKinds, TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Development.Shake.Internal.Core.Run(
    RunState,
    open,
    reset,
    run,
    shakeRunAfter,
    liveFilesState,
    profileState,
    errorsState
    ) where

import Control.Exception
import Data.Tuple.Extra
import Control.Concurrent.Extra hiding (withNumCapabilities)
import Control.Monad.IO.Class
import General.Binary
import Development.Shake.Internal.Core.Storage
import Development.Shake.Internal.History.Shared
import Development.Shake.Internal.History.Cloud
import qualified General.Ids as Ids
import qualified General.Intern as Intern
import qualified General.TypeMap as TMap
import General.Wait
import Control.Monad.Extra
import Data.Typeable
import Data.List.Extra
import qualified Data.HashMap.Strict as Map
import Data.Dynamic
import Data.Maybe
import Data.IORef
import System.Directory
import System.Time.Extra
import qualified Data.ByteString as BS

import Development.Shake.Internal.Core.Types
import Development.Shake.Internal.Core.Action
import Development.Shake.Internal.Core.Rules
import General.Pool
import Development.Shake.Internal.Progress
import Development.Shake.Internal.Value
import Development.Shake.Internal.Profile
import Development.Shake.Internal.Options
import Development.Shake.Internal.Errors
import General.Timing
import General.Thread
import General.Extra
import General.Cleanup
import Data.Monoid
import Prelude


---------------------------------------------------------------------
-- MAKE

data RunState = RunState
    {opts :: ShakeOptions
    ,ruleinfo :: Map.HashMap TypeRep BuiltinRule
    ,userRules :: TMap.Map UserRuleVersioned
    ,databaseVar :: Var Database
    ,curdir :: FilePath
    ,shared :: Maybe Shared
    ,cloud :: Maybe Cloud
    ,actions :: [(Stack, Action ())]
    }


open :: Cleanup -> ShakeOptions -> Rules () -> IO RunState
open cleanup opts rs = withInit opts $ \opts@ShakeOptions{..} diagnostic _ -> do
    diagnostic $ return "Starting run"
    (actions, ruleinfo, userRules, _targets) <- runRules opts rs

    diagnostic $ return $ "Number of actions = " ++ show (length actions)
    diagnostic $ return $ "Number of builtin rules = " ++ show (Map.size ruleinfo) ++ " " ++ show (Map.keys ruleinfo)
    diagnostic $ return $ "Number of user rule types = " ++ show (TMap.size userRules)
    diagnostic $ return $ "Number of user rules = " ++ show (sum (TMap.toList (userRuleSize . userRuleContents) userRules))

    checkShakeExtra shakeExtra
    curdir <- getCurrentDirectory

    databaseVar <- newVar =<< usingDatabase cleanup opts diagnostic ruleinfo
    (shared, cloud) <- loadSharedCloud databaseVar opts ruleinfo
    return RunState{..}


-- Prepare for a fresh run by changing Result to Loaded
reset :: RunState -> IO ()
reset RunState{..} = withVar databaseVar $ \database ->
    Ids.forMutate (status database) $ \(k, s) -> (k, f s)
    where
        f (Ready r) = Loaded (snd <$> r)
        f (Error _ x) = maybe Missing Loaded x
        f (Running _ x) = maybe Missing Loaded x -- shouldn't ever happen, but Loaded is least worst
        f x = x


run :: RunState -> Bool -> [Action ()] -> IO [IO ()]
run RunState{..} oneshot actions2 =
    withInit opts $ \opts@ShakeOptions{..} diagnostic output -> do

        -- timings are a bit delicate, we want to make sure we clear them before we leave (so each run is fresh)
        -- but we also want to only print them if there is no exception, and have to caputre them before we clear them
        -- we use this variable to stash them away, then print after the exception handling block
        timingsToShow <- newIORef Nothing

        res <- withCleanup $ \cleanup -> do
            register cleanup $ do
                when (shakeTimings && shakeVerbosity >= Normal) $
                    writeIORef timingsToShow . Just =<< getTimings
                resetTimings

            start <- offsetTime
            database <- readVar databaseVar
            except <- newIORef (Nothing :: Maybe (String, ShakeException))
            let getFailure = fmap fst <$> readIORef except
            let raiseError err
                    | not shakeStaunch = throwIO err
                    | otherwise = do
                        let named = shakeAbbreviationsApply opts . shakeExceptionTarget
                        atomicModifyIORef except $ \v -> (Just $ fromMaybe (named err, err) v, ())
                        -- no need to print exceptions here, they get printed when they are wrapped

            after <- newIORef []
            absent <- newIORef []
            step <- incrementStep database
            getProgress <- usingProgress cleanup opts database step getFailure
            lintCurrentDirectory curdir "When running"

            watch <- lintWatch shakeLintWatch
            let ruleFinished
                    | isJust shakeLint = \k -> do
                        liftIO $ lintCurrentDirectory curdir $ show k
                        lintTrackFinished
                        liftIO $ watch $ show k
                    | otherwise = liftIO . watch . show

            addTiming "Running rules"
            runPool (shakeThreads == 1) shakeThreads $ \pool -> do
                let global = Global databaseVar pool cleanup start ruleinfo output opts diagnostic ruleFinished after absent getProgress userRules shared cloud step oneshot
                -- give each action a stack to start with!
                forM_ (actions ++ map (emptyStack,) actions2) $ \(stack, act) -> do
                    let local = newLocal stack shakeVerbosity
                    addPool PoolStart pool $ runAction global local act $ \x -> case x of
                        Left e -> raiseError =<< shakeException global stack e
                        Right x -> return x
            maybe (return ()) (throwIO . snd) =<< readIORef except
            assertFinishedDatabase database

            let putWhen lvl msg = when (shakeVerbosity >= lvl) $ output lvl msg

            when (null actions && null actions2) $
                putWhen Normal "Warning: No want/action statements, nothing to do"

            when (isJust shakeLint) $ do
                addTiming "Lint checking"
                lintCurrentDirectory curdir "After completion"
                checkValid diagnostic database (runLint ruleinfo) =<< readIORef absent
                putWhen Loud "Lint checking succeeded"
            when (shakeReport /= []) $ do
                addTiming "Profile report"
                forM_ shakeReport $ \file -> do
                    putWhen Normal $ "Writing report to " ++ file
                    writeProfile file database
            when (shakeLiveFiles /= []) $ do
                addTiming "Listing live"
                diagnostic $ return "Listing live keys"
                xs <- liveFiles database
                forM_ shakeLiveFiles $ \file -> do
                    putWhen Normal $ "Writing live list to " ++ file
                    (if file == "-" then putStr else writeFile file) $ unlines xs

            res <- readIORef after
            addTiming "Cleanup"
            return res

        whenJustM (readIORef timingsToShow) $
            putStr . unlines
        return res


-- | Run a set of IO actions, treated as \"after\" actions, typically returned from
--   'Development.Shake.Database.shakeRunDatabase'. The actions will be run with diagnostics
--   etc as specified in the 'ShakeOptions'.
shakeRunAfter :: ShakeOptions -> [IO ()] -> IO ()
shakeRunAfter _ [] = return ()
shakeRunAfter opts after = withInit opts $ \ShakeOptions{..} diagnostic _ -> do
    let n = show $ length after
    diagnostic $ return $ "Running " ++ n ++ " after actions"
    (time, _) <- duration $ sequence_ $ reverse after
    when (shakeTimings && shakeVerbosity >= Normal) $
        putStrLn $ "(+ running " ++ show n ++ " after actions in " ++ showDuration time ++ ")"


withInit :: ShakeOptions -> (ShakeOptions -> (IO String -> IO ()) -> (Verbosity -> String -> IO ()) -> IO a) -> IO a
withInit opts act =
    withCleanup $ \cleanup -> do
        opts@ShakeOptions{..} <- usingShakeOptions cleanup opts
        (diagnostic, output) <- outputFunctions opts <$> newLock
        act opts diagnostic output


usingShakeOptions :: Cleanup -> ShakeOptions -> IO ShakeOptions
usingShakeOptions cleanup opts = do
    opts@ShakeOptions{..} <- if shakeThreads opts /= 0 then return opts else do p <- getProcessorCount; return opts{shakeThreads=p}
    when shakeLineBuffering $ usingLineBuffering cleanup
    usingNumCapabilities cleanup shakeThreads
    return opts

outputFunctions :: ShakeOptions -> Lock -> (IO String -> IO (), Verbosity -> String -> IO ())
outputFunctions opts@ShakeOptions{..} outputLock = (diagnostic, output)
    where
        outputLocked v msg = withLock outputLock $ shakeOutput v msg

        diagnostic | shakeVerbosity < Diagnostic = const $ return ()
                   | otherwise = \act -> do v <- act; outputLocked Diagnostic $ "% " ++ v
        output v = outputLocked v . shakeAbbreviationsApply opts


usingProgress :: Cleanup -> ShakeOptions -> Database -> Step -> IO (Maybe String) -> IO (IO Progress)
usingProgress cleanup ShakeOptions{..} database step getFailure = do
    let getProgress = do
            failure <- getFailure
            stats <- progress database step
            return stats{isFailure=failure}
    allocateThread cleanup $ shakeProgress getProgress
    return getProgress

checkShakeExtra :: Map.HashMap TypeRep Dynamic -> IO ()
checkShakeExtra mp = do
    let bad = [(k,t) | (k,v) <- Map.toList mp, let t = dynTypeRep v, t /= k]
    case bad of
        (k,t):xs -> throwIO $ errorStructured "Invalid Map in shakeExtra"
            [("Key",Just $ show k),("Value type",Just $ show t)]
            (if null xs then "" else "Plus " ++ show (length xs) ++ " other keys")
        _ -> return ()


runLint :: Map.HashMap TypeRep BuiltinRule -> Key -> Value -> IO (Maybe String)
runLint mp k v = case Map.lookup (typeKey k) mp of
    Nothing -> return Nothing
    Just BuiltinRule{..} -> builtinLint k v


assertFinishedDatabase :: Database -> IO ()
assertFinishedDatabase Database{..} = do
    -- if you have anyone Waiting, and are not exiting with an error, then must have a complex recursion (see #400)
    status <- Ids.elems status
    let bad = [key | (key, Running{}) <- status]
    when (bad /= []) $
        throwM $ errorComplexRecursion (map show bad)


liveFilesState :: RunState -> IO [FilePath]
liveFilesState RunState{..} = do
    database <- readVar databaseVar
    liveFiles database

profileState :: RunState -> FilePath -> IO ()
profileState RunState{..} file = do
    database <- readVar databaseVar
    writeProfile file database

liveFiles :: Database -> IO [FilePath]
liveFiles database = do
    status <- Ids.elems $ status database
    let specialIsFileKey t = show (fst $ splitTyConApp t) == "FileQ"
    return [show k | (k, Ready{}) <- status, specialIsFileKey $ typeKey k]

errorsState :: RunState -> IO [(String, SomeException)]
errorsState RunState{..} = do
    database <- readVar databaseVar
    status <- Ids.elems $ status database
    return [(show k, e) | (k, Error e _) <- status]


checkValid :: (IO String -> IO ()) -> Database -> (Key -> Value -> IO (Maybe String)) -> [(Key, Key)] -> IO ()
checkValid diagnostic Database{..} check missing = do
    status <- Ids.elems status
    intern <- readIORef intern
    diagnostic $ return "Starting validity/lint checking"

    -- Do not use a forM here as you use too much stack space
    bad <- (\f -> foldM f [] status) $ \seen v -> case v of
        (key, Ready Result{..}) -> do
            good <- check key $ fst result
            diagnostic $ return $ "Checking if " ++ show key ++ " is " ++ show result ++ ", " ++ if isNothing good then "passed" else "FAILED"
            return $ [(key, result, now) | Just now <- [good]] ++ seen
        _ -> return seen
    unless (null bad) $ do
        let n = length bad
        throwM $ errorStructured
            ("Lint checking error - " ++ (if n == 1 then "value has" else show n ++ " values have")  ++ " changed since being depended upon")
            (intercalate [("",Just "")] [ [("Key", Just $ show key),("Old", Just $ show result),("New", Just now)]
                                        | (key, result, now) <- bad])
            ""

    bad <- return [(parent,key) | (parent, key) <- missing, isJust $ Intern.lookup key intern]
    unless (null bad) $ do
        let n = length bad
        throwM $ errorStructured
            ("Lint checking error - " ++ (if n == 1 then "value" else show n ++ " values") ++ " did not have " ++ (if n == 1 then "its" else "their") ++ " creation tracked")
            (intercalate [("",Just "")] [ [("Rule", Just $ show parent), ("Created", Just $ show key)] | (parent,key) <- bad])
            ""

    diagnostic $ return "Validity/lint check passed"


---------------------------------------------------------------------
-- STORAGE

usingDatabase :: Cleanup -> ShakeOptions -> (IO String -> IO ()) -> Map.HashMap TypeRep BuiltinRule -> IO Database
usingDatabase cleanup opts diagnostic owitness = do
    let step = (typeRep (Proxy :: Proxy StepKey), (Ver 0, BinaryOp (const mempty) (const stepKey)))
    witness <- return $ Map.fromList
        [ (QTypeRep t, (version, BinaryOp (putDatabase putOp) (getDatabase getOp)))
        | (t,(version, BinaryOp{..})) <- step : Map.toList (Map.map (\BuiltinRule{..} -> (builtinVersion, builtinKey)) owitness)]
    (status, journal) <- usingStorage cleanup opts diagnostic witness
    journal <- return $ \i k v -> journal (QTypeRep $ typeKey k) i (k, Loaded v)

    xs <- Ids.toList status
    intern <- newIORef $ Intern.fromList [(k, i) | (i, (k,_)) <- xs]
    return Database{..}


incrementStep :: Database -> IO Step
incrementStep Database{..} = do
    is <- readIORef intern
    stepId <- case Intern.lookup stepKey is of
        Just stepId -> return stepId
        Nothing -> do
            (is, stepId) <- return $ Intern.add stepKey is
            writeIORef intern is
            return stepId
    step <- do
        v <- Ids.lookup status stepId
        return $ case v of
            Just (_, Loaded r) -> incStep $ fromStepResult r
            _ -> Step 1
    let stepRes = toStepResult step
    Ids.insert status stepId (stepKey, Ready stepRes)
    journal stepId stepKey $ fmap snd stepRes
    return step


loadSharedCloud :: Var a -> ShakeOptions -> Map.HashMap TypeRep BuiltinRule -> IO (Maybe Shared, Maybe Cloud)
loadSharedCloud var opts owitness = do
    let mp = Map.fromList $ map (first $ show . QTypeRep) $ Map.toList owitness
    let wit = binaryOpMap $ \a -> maybe (error $ "loadSharedCloud, couldn't find map for " ++ show a) builtinKey $ Map.lookup a mp
    let wit2 = BinaryOp (\k -> putOp wit (show $ QTypeRep $ typeKey k, k)) (snd . getOp wit)
    let keyVers = [(k, builtinVersion v) | (k,v) <- Map.toList owitness]
    let ver = makeVer $ shakeVersion opts

    shared <- case shakeShare opts of
        Nothing -> return Nothing
        Just x -> Just <$> newShared wit2 ver x
    cloud <- case newCloud (runLocked var . const) (Map.map builtinKey owitness) ver keyVers $ shakeCloud opts of
        _ | null $ shakeCloud opts -> return Nothing
        Nothing -> fail "shakeCloud set but Shake not compiled for cloud operation"
        Just res -> Just <$> res
    return (shared, cloud)


putDatabase :: (Key -> Builder) -> ((Key, Status) -> Builder)
putDatabase putKey (key, Loaded (Result x1 x2 x3 x4 x5 x6)) =
    putExN (putKey key) <> putExN (putEx x1) <> putEx x2 <> putEx x3 <> putEx x5 <> putExN (putEx x4) <> putEx x6
putDatabase _ (_, x) = throwImpure $ errorInternal $ "putWith, Cannot write Status with constructor " ++ statusType x


getDatabase :: (BS.ByteString -> Key) -> BS.ByteString -> (Key, Status)
getDatabase getKey bs
    | (key, bs) <- getExN bs
    , (x1, bs) <- getExN bs
    , (x2, x3, x5, bs) <- binarySplit3 bs
    , (x4, x6) <- getExN bs
    = (getKey key, Loaded (Result x1 x2 x3 (getEx x4) x5 (getEx x6)))
