{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The Config type.

module Stack.Types.Config where

import           Control.Applicative
import           Control.Arrow ((&&&))
import           Control.Exception
import           Control.Monad (liftM, mzero, forM)
import           Control.Monad.Catch (MonadThrow, throwM)
import           Control.Monad.Logger (LogLevel(..))
import           Control.Monad.Reader (MonadReader, ask, asks, MonadIO, liftIO)
import           Data.Aeson.Extended
                 (ToJSON, toJSON, FromJSON, parseJSON, withText, object,
                  (.=), (..:), (..:?), (..!=), Value(String, Object),
                  withObjectWarnings, WarningParser, Object, jsonSubWarnings, JSONWarning,
                  jsonSubWarningsT, jsonSubWarningsTT)
import           Data.Attoparsec.Args
import           Data.Binary (Binary)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S8
import           Data.Either (partitionEithers)
import           Data.List (stripPrefix)
import           Data.Hashable (Hashable)
import           Data.Map (Map)
import qualified Data.Map as Map

import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8, decodeUtf8)
import           Data.Typeable
import           Data.Yaml (ParseException)
import           Distribution.System (Platform)
import qualified Distribution.Text
import           Distribution.Version (anyVersion)
import           Network.HTTP.Client (parseUrl)
import           Path
import qualified Paths_stack as Meta
import           Stack.Types.BuildPlan (SnapName, renderSnapName, parseSnapName)
import           Stack.Types.Compiler
import           Stack.Types.Docker
import           Stack.Types.FlagName
import           Stack.Types.Image
import           Stack.Types.PackageIdentifier
import           Stack.Types.PackageName
import           Stack.Types.Version
import           System.Process.Read (EnvOverride)

-- | The top-level Stackage configuration.
data Config =
  Config {configStackRoot           :: !(Path Abs Dir)
         -- ^ ~/.stack more often than not
         ,configUserConfigPath      :: !(Path Abs File)
         -- ^ Path to user configuration file (usually ~/.stack/config.yaml)
         ,configDocker              :: !DockerOpts
         -- ^ Docker configuration
         ,configEnvOverride         :: !(EnvSettings -> IO EnvOverride)
         -- ^ Environment variables to be passed to external tools
         ,configLocalProgramsBase   :: !(Path Abs Dir)
         -- ^ Non-platform-specific path containing local installations
         ,configLocalPrograms       :: !(Path Abs Dir)
         -- ^ Path containing local installations (mainly GHC)
         ,configConnectionCount     :: !Int
         -- ^ How many concurrent connections are allowed when downloading
         ,configHideTHLoading       :: !Bool
         -- ^ Hide the Template Haskell "Loading package ..." messages from the
         -- console
         ,configPlatform            :: !Platform
         -- ^ The platform we're building for, used in many directory names
         ,configGHCVariant0         :: !(Maybe GHCVariant)
         -- ^ The variant of GHC requested by the user.
         -- In most cases, use 'BuildConfig' or 'MiniConfig's version instead,
         -- which will have an auto-detected default.
         ,configLatestSnapshotUrl   :: !Text
         -- ^ URL for a JSON file containing information on the latest
         -- snapshots available.
         ,configPackageIndices      :: ![PackageIndex]
         -- ^ Information on package indices. This is left biased, meaning that
         -- packages in an earlier index will shadow those in a later index.
         --
         -- Warning: if you override packages in an index vs what's available
         -- upstream, you may correct your compiled snapshots, as different
         -- projects may have different definitions of what pkg-ver means! This
         -- feature is primarily intended for adding local packages, not
         -- overriding. Overriding is better accomplished by adding to your
         -- list of packages.
         --
         -- Note that indices specified in a later config file will override
         -- previous indices, /not/ extend them.
         --
         -- Using an assoc list instead of a Map to keep track of priority
         ,configSystemGHC           :: !Bool
         -- ^ Should we use the system-installed GHC (on the PATH) if
         -- available? Can be overridden by command line options.
         ,configInstallGHC          :: !Bool
         -- ^ Should we automatically install GHC if missing or the wrong
         -- version is available? Can be overridden by command line options.
         ,configSkipGHCCheck        :: !Bool
         -- ^ Don't bother checking the GHC version or architecture.
         ,configSkipMsys            :: !Bool
         -- ^ On Windows: don't use a locally installed MSYS
         ,configCompilerCheck       :: !VersionCheck
         -- ^ Specifies which versions of the compiler are acceptable.
         ,configLocalBin            :: !(Path Abs Dir)
         -- ^ Directory we should install executables into
         ,configRequireStackVersion :: !VersionRange
         -- ^ Require a version of stack within this range.
         ,configJobs                :: !Int
         -- ^ How many concurrent jobs to run, defaults to number of capabilities
         ,configExtraIncludeDirs    :: !(Set Text)
         -- ^ --extra-include-dirs arguments
         ,configExtraLibDirs        :: !(Set Text)
         -- ^ --extra-lib-dirs arguments
         ,configConfigMonoid        :: !ConfigMonoid
         -- ^ @ConfigMonoid@ used to generate this
         ,configConcurrentTests     :: !Bool
         -- ^ Run test suites concurrently
         ,configImage               :: !ImageOpts
         ,configTemplateParams      :: !(Map Text Text)
         -- ^ Parameters for templates.
         ,configScmInit             :: !(Maybe SCM)
         -- ^ Initialize SCM (e.g. git) when creating new projects.
         ,configGhcOptions          :: !(Map (Maybe PackageName) [Text])
         -- ^ Additional GHC options to apply to either all packages (Nothing)
         -- or a specific package (Just).
         ,configSetupInfoLocations  :: ![SetupInfoLocation]
         -- ^ Additional SetupInfo (inline or remote) to use to find tools.
         ,configPvpBounds           :: !PvpBounds
         -- ^ How PVP upper bounds should be added to packages
         ,configModifyCodePage      :: !Bool
         -- ^ Force the code page to UTF-8 on Windows
         ,configExplicitSetupDeps   :: !(Map (Maybe PackageName) Bool)
         -- ^ See 'explicitSetupDeps'. 'Nothing' provides the default value.
         ,configRebuildGhcOptions   :: !Bool
         -- ^ Rebuild on GHC options changes
         ,configApplyGhcOptions     :: !ApplyGhcOptions
         -- ^ Which packages to ghc-options on the command line apply to?
         }

-- | Which packages to ghc-options on the command line apply to?
data ApplyGhcOptions = AGOTargets -- ^ all local targets
                     | AGOLocals -- ^ all local packages, even non-targets
                     | AGOEverything -- ^ every package
  deriving (Show, Read, Eq, Ord, Enum, Bounded)

instance FromJSON ApplyGhcOptions where
    parseJSON = withText "ApplyGhcOptions" $ \t ->
        case t of
            "targets" -> return AGOTargets
            "locals" -> return AGOLocals
            "everything" -> return AGOEverything
            _ -> fail $ "Invalid ApplyGhcOptions: " ++ show t

-- | Information on a single package index
data PackageIndex = PackageIndex
    { indexName :: !IndexName
    , indexLocation :: !IndexLocation
    , indexDownloadPrefix :: !Text
    -- ^ URL prefix for downloading packages
    , indexGpgVerify :: !Bool
    -- ^ GPG-verify the package index during download. Only applies to Git
    -- repositories for now.
    , indexRequireHashes :: !Bool
    -- ^ Require that hashes and package size information be available for packages in this index
    }
    deriving Show
instance FromJSON (PackageIndex, [JSONWarning]) where
    parseJSON = withObjectWarnings "PackageIndex" $ \o -> do
        name <- o ..: "name"
        prefix <- o ..: "download-prefix"
        mgit <- o ..:? "git"
        mhttp <- o ..:? "http"
        loc <-
            case (mgit, mhttp) of
                (Nothing, Nothing) -> fail $
                    "Must provide either Git or HTTP URL for " ++
                    T.unpack (indexNameText name)
                (Just git, Nothing) -> return $ ILGit git
                (Nothing, Just http) -> return $ ILHttp http
                (Just git, Just http) -> return $ ILGitHttp git http
        gpgVerify <- o ..:? "gpg-verify" ..!= False
        reqHashes <- o ..:? "require-hashes" ..!= False
        return PackageIndex
            { indexName = name
            , indexLocation = loc
            , indexDownloadPrefix = prefix
            , indexGpgVerify = gpgVerify
            , indexRequireHashes = reqHashes
            }

-- | Unique name for a package index
newtype IndexName = IndexName { unIndexName :: ByteString }
    deriving (Show, Eq, Ord, Hashable, Binary)
indexNameText :: IndexName -> Text
indexNameText = decodeUtf8 . unIndexName
instance ToJSON IndexName where
    toJSON = toJSON . indexNameText
instance FromJSON IndexName where
    parseJSON = withText "IndexName" $ \t ->
        case parseRelDir (T.unpack t) of
            Left e -> fail $ "Invalid index name: " ++ show e
            Right _ -> return $ IndexName $ encodeUtf8 t

-- | Location of the package index. This ensures that at least one of Git or
-- HTTP is available.
data IndexLocation = ILGit !Text | ILHttp !Text | ILGitHttp !Text !Text
    deriving (Show, Eq, Ord)

-- | Controls which version of the environment is used
data EnvSettings = EnvSettings
    { esIncludeLocals :: !Bool
    -- ^ include local project bin directory, GHC_PACKAGE_PATH, etc
    , esIncludeGhcPackagePath :: !Bool
    -- ^ include the GHC_PACKAGE_PATH variable
    , esStackExe :: !Bool
    -- ^ set the STACK_EXE variable to the current executable name
    , esLocaleUtf8 :: !Bool
    -- ^ set the locale to C.UTF-8
    }
    deriving (Show, Eq, Ord)

data ExecOpts = ExecOpts
    { eoCmd :: !(Maybe String)
    -- ^ Usage of @Maybe@ here is nothing more than a hack, to avoid some weird
    -- bug in optparse-applicative. See:
    -- https://github.com/commercialhaskell/stack/issues/806
    , eoArgs :: ![String]
    , eoExtra :: !ExecOptsExtra
    }

data ExecOptsExtra
    = ExecOptsPlain
    | ExecOptsEmbellished
        { eoEnvSettings :: !EnvSettings
        , eoPackages :: ![String]
        }

data EvalOpts = EvalOpts
    { evalArg :: !String
    , evalExtra :: !ExecOptsExtra
    }

-- | Parsed global command-line options.
data GlobalOpts = GlobalOpts
    { globalReExecVersion :: !(Maybe String) -- ^ Expected re-exec in container version
    , globalLogLevel     :: !LogLevel -- ^ Log level
    , globalConfigMonoid :: !ConfigMonoid -- ^ Config monoid, for passing into 'loadConfig'
    , globalResolver     :: !(Maybe AbstractResolver) -- ^ Resolver override
    , globalTerminal     :: !Bool -- ^ We're in a terminal?
    , globalStackYaml    :: !(Maybe FilePath) -- ^ Override project stack.yaml
    } deriving (Show)

-- | Either an actual resolver value, or an abstract description of one (e.g.,
-- latest nightly).
data AbstractResolver
    = ARLatestNightly
    | ARLatestLTS
    | ARLatestLTSMajor !Int
    | ARResolver !Resolver
    | ARGlobal
    deriving Show

-- | Default logging level should be something useful but not crazy.
defaultLogLevel :: LogLevel
defaultLogLevel = LevelInfo

-- | A superset of 'Config' adding information on how to build code. The reason
-- for this breakdown is because we will need some of the information from
-- 'Config' in order to determine the values here.
data BuildConfig = BuildConfig
    { bcConfig     :: !Config
    , bcResolver   :: !Resolver
      -- ^ How we resolve which dependencies to install given a set of
      -- packages.
    , bcWantedCompiler :: !CompilerVersion
      -- ^ Compiler version wanted for this build
    , bcPackageEntries :: ![PackageEntry]
      -- ^ Local packages identified by a path, Bool indicates whether it is
      -- a non-dependency (the opposite of 'peExtraDep')
    , bcExtraDeps  :: !(Map PackageName Version)
      -- ^ Extra dependencies specified in configuration.
      --
      -- These dependencies will not be installed to a shared location, and
      -- will override packages provided by the resolver.
    , bcExtraPackageDBs :: ![Path Abs Dir]
      -- ^ Extra package databases
    , bcStackYaml  :: !(Path Abs File)
      -- ^ Location of the stack.yaml file.
      --
      -- Note: if the STACK_YAML environment variable is used, this may be
      -- different from bcRoot </> "stack.yaml"
    , bcFlags      :: !(Map PackageName (Map FlagName Bool))
      -- ^ Per-package flag overrides
    , bcImplicitGlobal :: !Bool
      -- ^ Are we loading from the implicit global stack.yaml? This is useful
      -- for providing better error messages.
    , bcGHCVariant :: !GHCVariant
      -- ^ The variant of GHC used to select a GHC bindist.
    }

-- | Directory containing the project's stack.yaml file
bcRoot :: BuildConfig -> Path Abs Dir
bcRoot = parent . bcStackYaml

-- | Directory containing the project's stack.yaml file
bcWorkDir :: BuildConfig -> Path Abs Dir
bcWorkDir = (</> workDirRel) . parent . bcStackYaml

-- | Configuration after the environment has been setup.
data EnvConfig = EnvConfig
    {envConfigBuildConfig :: !BuildConfig
    ,envConfigCabalVersion :: !Version
    ,envConfigCompilerVersion :: !CompilerVersion
    ,envConfigPackages   :: !(Map (Path Abs Dir) Bool)}
instance HasBuildConfig EnvConfig where
    getBuildConfig = envConfigBuildConfig
instance HasConfig EnvConfig
instance HasPlatform EnvConfig
instance HasGHCVariant EnvConfig
instance HasStackRoot EnvConfig
class (HasBuildConfig r, HasGHCVariant r) => HasEnvConfig r where
    getEnvConfig :: r -> EnvConfig
instance HasEnvConfig EnvConfig where
    getEnvConfig = id

-- | Value returned by 'Stack.Config.loadConfig'.
data LoadConfig m = LoadConfig
    { lcConfig          :: !Config
      -- ^ Top-level Stack configuration.
    , lcLoadBuildConfig :: !(Maybe AbstractResolver -> m BuildConfig)
        -- ^ Action to load the remaining 'BuildConfig'.
    , lcProjectRoot     :: !(Maybe (Path Abs Dir))
        -- ^ The project root directory, if in a project.
    }

data PackageEntry = PackageEntry
    { peExtraDepMaybe :: !(Maybe Bool)
    -- ^ Is this package a dependency? This means the local package will be
    -- treated just like an extra-deps: it will only be built as a dependency
    -- for others, and its test suite/benchmarks will not be run.
    --
    -- Useful modifying an upstream package, see:
    -- https://github.com/commercialhaskell/stack/issues/219
    -- https://github.com/commercialhaskell/stack/issues/386
    , peValidWanted :: !(Maybe Bool)
    -- ^ Deprecated name meaning the opposite of peExtraDep. Only present to
    -- provide deprecation warnings to users.
    , peLocation :: !PackageLocation
    , peSubdirs :: ![FilePath]
    }
    deriving Show

-- | Once peValidWanted is removed, this should just become the field name in PackageEntry.
peExtraDep :: PackageEntry -> Bool
peExtraDep pe =
    case peExtraDepMaybe pe of
        Just x -> x
        Nothing ->
            case peValidWanted pe of
                Just x -> not x
                Nothing -> False

instance ToJSON PackageEntry where
    toJSON pe | not (peExtraDep pe) && null (peSubdirs pe) =
        toJSON $ peLocation pe
    toJSON pe = object
        [ "extra-dep" .= peExtraDep pe
        , "location" .= peLocation pe
        , "subdirs" .= peSubdirs pe
        ]
instance FromJSON (PackageEntry, [JSONWarning]) where
    parseJSON (String t) = do
        (loc, _::[JSONWarning]) <- parseJSON $ String t
        return (PackageEntry
                { peExtraDepMaybe = Nothing
                , peValidWanted = Nothing
                , peLocation = loc
                , peSubdirs = []
                }, [])
    parseJSON v = withObjectWarnings "PackageEntry" (\o -> PackageEntry
        <$> o ..:? "extra-dep"
        <*> o ..:? "valid-wanted"
        <*> jsonSubWarnings (o ..: "location")
        <*> o ..:? "subdirs" ..!= []) v

data PackageLocation
    = PLFilePath FilePath
    -- ^ Note that we use @FilePath@ and not @Path@s. The goal is: first parse
    -- the value raw, and then use @canonicalizePath@ and @parseAbsDir@.
    | PLHttpTarball Text
    | PLGit Text Text
    -- ^ URL and commit
    deriving Show
instance ToJSON PackageLocation where
    toJSON (PLFilePath fp) = toJSON fp
    toJSON (PLHttpTarball t) = toJSON t
    toJSON (PLGit x y) = toJSON $ T.unwords ["git", x, y]
instance FromJSON (PackageLocation, [JSONWarning]) where
    parseJSON v = ((,[]) <$> withText "PackageLocation" (\t -> http t <|> file t) v) <|> git v
      where
        file t = pure $ PLFilePath $ T.unpack t
        http t =
            case parseUrl $ T.unpack t of
                Left _ -> mzero
                Right _ -> return $ PLHttpTarball t
        git = withObjectWarnings "PackageGitLocation" $ \o -> PLGit
            <$> o ..: "git"
            <*> o ..: "commit"

-- | A project is a collection of packages. We can have multiple stack.yaml
-- files, but only one of them may contain project information.
data Project = Project
    { projectPackages :: ![PackageEntry]
    -- ^ Components of the package list
    , projectExtraDeps :: !(Map PackageName Version)
    -- ^ Components of the package list referring to package/version combos,
    -- see: https://github.com/fpco/stack/issues/41
    , projectFlags :: !(Map PackageName (Map FlagName Bool))
    -- ^ Per-package flag overrides
    , projectResolver :: !Resolver
    -- ^ How we resolve which dependencies to use
    , projectExtraPackageDBs :: ![FilePath]
    }
  deriving Show

instance ToJSON Project where
    toJSON p = object
        [ "packages"          .= projectPackages p
        , "extra-deps"        .= map fromTuple (Map.toList $ projectExtraDeps p)
        , "flags"             .= projectFlags p
        , "resolver"          .= projectResolver p
        , "extra-package-dbs" .= projectExtraPackageDBs p
        ]

-- | How we resolve which dependencies to install given a set of packages.
data Resolver
  = ResolverSnapshot SnapName
  -- ^ Use an official snapshot from the Stackage project, either an LTS
  -- Haskell or Stackage Nightly

  | ResolverCompiler !CompilerVersion
  -- ^ Require a specific compiler version, but otherwise provide no build plan.
  -- Intended for use cases where end user wishes to specify all upstream
  -- dependencies manually, such as using a dependency solver.

  | ResolverCustom !Text !Text
  -- ^ A custom resolver based on the given name and URL. This file is assumed
  -- to be completely immutable.
  deriving (Show)

instance ToJSON Resolver where
    toJSON (ResolverCustom name location) = object
        [ "name" .= name
        , "location" .= location
        ]
    toJSON x = toJSON $ resolverName x
instance FromJSON (Resolver,[JSONWarning]) where
    -- Strange structuring is to give consistent error messages
    parseJSON v@(Object _) = withObjectWarnings "Resolver" (\o -> ResolverCustom
        <$> o ..: "name"
        <*> o ..: "location") v

    parseJSON (String t) = either (fail . show) return ((,[]) <$> parseResolverText t)

    parseJSON _ = fail $ "Invalid Resolver, must be Object or String"

-- | Convert a Resolver into its @Text@ representation, as will be used by
-- directory names
resolverName :: Resolver -> Text
resolverName (ResolverSnapshot name) = renderSnapName name
resolverName (ResolverCompiler v) = compilerVersionText v
resolverName (ResolverCustom name _) = "custom-" <> name

-- | Try to parse a @Resolver@ from a @Text@. Won't work for complex resolvers (like custom).
parseResolverText :: MonadThrow m => Text -> m Resolver
parseResolverText t
    | Right x <- parseSnapName t = return $ ResolverSnapshot x
    | Just v <- parseCompilerVersion t = return $ ResolverCompiler v
    | otherwise = throwM $ ParseResolverException t

-- | Class for environment values which have access to the stack root
class HasStackRoot env where
    getStackRoot :: env -> Path Abs Dir
    default getStackRoot :: HasConfig env => env -> Path Abs Dir
    getStackRoot = configStackRoot . getConfig
    {-# INLINE getStackRoot #-}

-- | Class for environment values which have a Platform
class HasPlatform env where
    getPlatform :: env -> Platform
    default getPlatform :: HasConfig env => env -> Platform
    getPlatform = configPlatform . getConfig
    {-# INLINE getPlatform #-}
instance HasPlatform Platform where
    getPlatform = id

-- | Class for environment values which have a GHCVariant
class HasGHCVariant env where
    getGHCVariant :: env -> GHCVariant
    default getGHCVariant :: HasBuildConfig env => env -> GHCVariant
    getGHCVariant = bcGHCVariant . getBuildConfig
    {-# INLINE getGHCVariant #-}
instance HasGHCVariant GHCVariant where
    getGHCVariant = id

-- | Class for environment values that can provide a 'Config'.
class (HasStackRoot env, HasPlatform env) => HasConfig env where
    getConfig :: env -> Config
    default getConfig :: HasBuildConfig env => env -> Config
    getConfig = bcConfig . getBuildConfig
    {-# INLINE getConfig #-}
instance HasStackRoot Config
instance HasPlatform Config
instance HasConfig Config where
    getConfig = id
    {-# INLINE getConfig #-}

-- | Class for environment values that can provide a 'BuildConfig'.
class HasConfig env => HasBuildConfig env where
    getBuildConfig :: env -> BuildConfig
instance HasStackRoot BuildConfig
instance HasPlatform BuildConfig
instance HasGHCVariant BuildConfig
instance HasConfig BuildConfig
instance HasBuildConfig BuildConfig where
    getBuildConfig = id
    {-# INLINE getBuildConfig #-}

-- An uninterpreted representation of configuration options.
-- Configurations may be "cascaded" using mappend (left-biased).
data ConfigMonoid =
  ConfigMonoid
    { configMonoidDockerOpts         :: !DockerOptsMonoid
    -- ^ Docker options.
    , configMonoidConnectionCount    :: !(Maybe Int)
    -- ^ See: 'configConnectionCount'
    , configMonoidHideTHLoading      :: !(Maybe Bool)
    -- ^ See: 'configHideTHLoading'
    , configMonoidLatestSnapshotUrl  :: !(Maybe Text)
    -- ^ See: 'configLatestSnapshotUrl'
    , configMonoidPackageIndices     :: !(Maybe [PackageIndex])
    -- ^ See: 'configPackageIndices'
    , configMonoidSystemGHC          :: !(Maybe Bool)
    -- ^ See: 'configSystemGHC'
    ,configMonoidInstallGHC          :: !(Maybe Bool)
    -- ^ See: 'configInstallGHC'
    ,configMonoidSkipGHCCheck        :: !(Maybe Bool)
    -- ^ See: 'configSkipGHCCheck'
    ,configMonoidSkipMsys            :: !(Maybe Bool)
    -- ^ See: 'configSkipMsys'
    ,configMonoidCompilerCheck       :: !(Maybe VersionCheck)
    -- ^ See: 'configCompilerCheck'
    ,configMonoidRequireStackVersion :: !VersionRange
    -- ^ See: 'configRequireStackVersion'
    ,configMonoidOS                  :: !(Maybe String)
    -- ^ Used for overriding the platform
    ,configMonoidArch                :: !(Maybe String)
    -- ^ Used for overriding the platform
    ,configMonoidGHCVariant          :: !(Maybe GHCVariant)
    -- ^ Used for overriding the GHC variant
    ,configMonoidJobs                :: !(Maybe Int)
    -- ^ See: 'configJobs'
    ,configMonoidExtraIncludeDirs    :: !(Set Text)
    -- ^ See: 'configExtraIncludeDirs'
    ,configMonoidExtraLibDirs        :: !(Set Text)
    -- ^ See: 'configExtraLibDirs'
    ,configMonoidConcurrentTests     :: !(Maybe Bool)
    -- ^ See: 'configConcurrentTests'
    ,configMonoidLocalBinPath        :: !(Maybe FilePath)
    -- ^ Used to override the binary installation dir
    ,configMonoidImageOpts           :: !ImageOptsMonoid
    -- ^ Image creation options.
    ,configMonoidTemplateParameters  :: !(Map Text Text)
    -- ^ Template parameters.
    ,configMonoidScmInit             :: !(Maybe SCM)
    -- ^ Initialize SCM (e.g. git init) when making new projects?
    ,configMonoidGhcOptions          :: !(Map (Maybe PackageName) [Text])
    -- ^ See 'configGhcOptions'
    ,configMonoidExtraPath           :: ![Path Abs Dir]
    -- ^ Additional paths to search for executables in
    ,configMonoidSetupInfoLocations  :: ![SetupInfoLocation]
    -- ^ Additional setup info (inline or remote) to use for installing tools
    ,configMonoidPvpBounds           :: !(Maybe PvpBounds)
    -- ^ See 'configPvpBounds'
    ,configMonoidModifyCodePage      :: !(Maybe Bool)
    -- ^ See 'configModifyCodePage'
    ,configMonoidExplicitSetupDeps   :: !(Map (Maybe PackageName) Bool)
    -- ^ See 'configExplicitSetupDeps'
    ,configMonoidRebuildGhcOptions   :: !(Maybe Bool)
    -- ^ See 'configMonoidRebuildGhcOptions'
    ,configMonoidApplyGhcOptions     :: !(Maybe ApplyGhcOptions)
    }
  deriving Show

instance Monoid ConfigMonoid where
  mempty = ConfigMonoid
    { configMonoidDockerOpts = mempty
    , configMonoidConnectionCount = Nothing
    , configMonoidHideTHLoading = Nothing
    , configMonoidLatestSnapshotUrl = Nothing
    , configMonoidPackageIndices = Nothing
    , configMonoidSystemGHC = Nothing
    , configMonoidInstallGHC = Nothing
    , configMonoidSkipGHCCheck = Nothing
    , configMonoidSkipMsys = Nothing
    , configMonoidRequireStackVersion = anyVersion
    , configMonoidOS = Nothing
    , configMonoidArch = Nothing
    , configMonoidGHCVariant = Nothing
    , configMonoidJobs = Nothing
    , configMonoidExtraIncludeDirs = Set.empty
    , configMonoidExtraLibDirs = Set.empty
    , configMonoidConcurrentTests = Nothing
    , configMonoidLocalBinPath = Nothing
    , configMonoidImageOpts = mempty
    , configMonoidTemplateParameters = mempty
    , configMonoidScmInit = Nothing
    , configMonoidCompilerCheck = Nothing
    , configMonoidGhcOptions = mempty
    , configMonoidExtraPath = []
    , configMonoidSetupInfoLocations = mempty
    , configMonoidPvpBounds = Nothing
    , configMonoidModifyCodePage = Nothing
    , configMonoidExplicitSetupDeps = mempty
    , configMonoidRebuildGhcOptions = Nothing
    , configMonoidApplyGhcOptions = Nothing
    }
  mappend l r = ConfigMonoid
    { configMonoidDockerOpts = configMonoidDockerOpts l <> configMonoidDockerOpts r
    , configMonoidConnectionCount = configMonoidConnectionCount l <|> configMonoidConnectionCount r
    , configMonoidHideTHLoading = configMonoidHideTHLoading l <|> configMonoidHideTHLoading r
    , configMonoidLatestSnapshotUrl = configMonoidLatestSnapshotUrl l <|> configMonoidLatestSnapshotUrl r
    , configMonoidPackageIndices = configMonoidPackageIndices l <|> configMonoidPackageIndices r
    , configMonoidSystemGHC = configMonoidSystemGHC l <|> configMonoidSystemGHC r
    , configMonoidInstallGHC = configMonoidInstallGHC l <|> configMonoidInstallGHC r
    , configMonoidSkipGHCCheck = configMonoidSkipGHCCheck l <|> configMonoidSkipGHCCheck r
    , configMonoidSkipMsys = configMonoidSkipMsys l <|> configMonoidSkipMsys r
    , configMonoidRequireStackVersion = intersectVersionRanges (configMonoidRequireStackVersion l)
                                                               (configMonoidRequireStackVersion r)
    , configMonoidOS = configMonoidOS l <|> configMonoidOS r
    , configMonoidArch = configMonoidArch l <|> configMonoidArch r
    , configMonoidGHCVariant = configMonoidGHCVariant l <|> configMonoidGHCVariant r
    , configMonoidJobs = configMonoidJobs l <|> configMonoidJobs r
    , configMonoidExtraIncludeDirs = Set.union (configMonoidExtraIncludeDirs l) (configMonoidExtraIncludeDirs r)
    , configMonoidExtraLibDirs = Set.union (configMonoidExtraLibDirs l) (configMonoidExtraLibDirs r)
    , configMonoidConcurrentTests = configMonoidConcurrentTests l <|> configMonoidConcurrentTests r
    , configMonoidLocalBinPath = configMonoidLocalBinPath l <|> configMonoidLocalBinPath r
    , configMonoidImageOpts = configMonoidImageOpts l <> configMonoidImageOpts r
    , configMonoidTemplateParameters = configMonoidTemplateParameters l <> configMonoidTemplateParameters r
    , configMonoidScmInit = configMonoidScmInit l <|> configMonoidScmInit r
    , configMonoidCompilerCheck = configMonoidCompilerCheck l <|> configMonoidCompilerCheck r
    , configMonoidGhcOptions = Map.unionWith (++) (configMonoidGhcOptions l) (configMonoidGhcOptions r)
    , configMonoidExtraPath = configMonoidExtraPath l ++ configMonoidExtraPath r
    , configMonoidSetupInfoLocations = configMonoidSetupInfoLocations l ++ configMonoidSetupInfoLocations r
    , configMonoidPvpBounds = configMonoidPvpBounds l <|> configMonoidPvpBounds r
    , configMonoidModifyCodePage = configMonoidModifyCodePage l <|> configMonoidModifyCodePage r
    , configMonoidExplicitSetupDeps = configMonoidExplicitSetupDeps l <> configMonoidExplicitSetupDeps r
    , configMonoidRebuildGhcOptions = configMonoidRebuildGhcOptions l <|> configMonoidRebuildGhcOptions r
    , configMonoidApplyGhcOptions = configMonoidApplyGhcOptions l <|> configMonoidApplyGhcOptions r
    }

instance FromJSON (ConfigMonoid, [JSONWarning]) where
  parseJSON = withObjectWarnings "ConfigMonoid" parseConfigMonoidJSON

-- | Parse a partial configuration.  Used both to parse both a standalone config
-- file and a project file, so that a sub-parser is not required, which would interfere with
-- warnings for missing fields.
parseConfigMonoidJSON :: Object -> WarningParser ConfigMonoid
parseConfigMonoidJSON obj = do
    configMonoidDockerOpts <- jsonSubWarnings (obj ..:? "docker" ..!= mempty)
    configMonoidConnectionCount <- obj ..:? "connection-count"
    configMonoidHideTHLoading <- obj ..:? "hide-th-loading"
    configMonoidLatestSnapshotUrl <- obj ..:? "latest-snapshot-url"
    configMonoidPackageIndices <- jsonSubWarningsTT (obj ..:? "package-indices")
    configMonoidSystemGHC <- obj ..:? "system-ghc"
    configMonoidInstallGHC <- obj ..:? "install-ghc"
    configMonoidSkipGHCCheck <- obj ..:? "skip-ghc-check"
    configMonoidSkipMsys <- obj ..:? "skip-msys"
    configMonoidRequireStackVersion <- unVersionRangeJSON <$>
                                       obj ..:? "require-stack-version"
                                           ..!= VersionRangeJSON anyVersion
    configMonoidOS <- obj ..:? "os"
    configMonoidArch <- obj ..:? "arch"
    configMonoidGHCVariant <- obj ..:? "ghc-variant"
    configMonoidJobs <- obj ..:? "jobs"
    configMonoidExtraIncludeDirs <- obj ..:? "extra-include-dirs" ..!= Set.empty
    configMonoidExtraLibDirs <- obj ..:? "extra-lib-dirs" ..!= Set.empty
    configMonoidConcurrentTests <- obj ..:? "concurrent-tests"
    configMonoidLocalBinPath <- obj ..:? "local-bin-path"
    configMonoidImageOpts <- jsonSubWarnings (obj ..:? "image" ..!= mempty)
    templates <- obj ..:? "templates"
    (configMonoidScmInit,configMonoidTemplateParameters) <-
      case templates of
        Nothing -> return (Nothing,M.empty)
        Just tobj -> do
          scmInit <- tobj ..:? "scm-init"
          params <- tobj ..:? "params"
          return (scmInit,fromMaybe M.empty params)
    configMonoidCompilerCheck <- obj ..:? "compiler-check"

    mghcoptions <- obj ..:? "ghc-options"
    configMonoidGhcOptions <-
        case mghcoptions of
            Nothing -> return mempty
            Just m -> fmap Map.fromList $ mapM handleGhcOptions $ Map.toList m

    extraPath <- obj ..:? "extra-path" ..!= []
    configMonoidExtraPath <- forM extraPath $
        either (fail . show) return . parseAbsDir . T.unpack

    configMonoidSetupInfoLocations <-
        maybeToList <$> jsonSubWarningsT (obj ..:? "setup-info")

    configMonoidPvpBounds <- obj ..:? "pvp-bounds"
    configMonoidModifyCodePage <- obj ..:? "modify-code-page"
    configMonoidExplicitSetupDeps <-
        (obj ..:? "explicit-setup-deps" ..!= mempty)
        >>= fmap Map.fromList . mapM handleExplicitSetupDep . Map.toList
    configMonoidRebuildGhcOptions <- obj ..:? "rebuild-ghc-options"
    configMonoidApplyGhcOptions <- obj ..:? "apply-ghc-options"

    return ConfigMonoid {..}
  where
    handleGhcOptions :: Monad m => (Text, Text) -> m (Maybe PackageName, [Text])
    handleGhcOptions (name', vals') = do
        name <-
            if name' == "*"
                then return Nothing
                else case parsePackageNameFromString $ T.unpack name' of
                        Left e -> fail $ show e
                        Right x -> return $ Just x

        case parseArgs Escaping vals' of
            Left e -> fail e
            Right vals -> return (name, map T.pack vals)

    handleExplicitSetupDep :: Monad m => (Text, Bool) -> m (Maybe PackageName, Bool)
    handleExplicitSetupDep (name', b) = do
        name <-
            if name' == "*"
                then return Nothing
                else case parsePackageNameFromString $ T.unpack name' of
                        Left e -> fail $ show e
                        Right x -> return $ Just x
        return (name, b)

-- | Newtype for non-orphan FromJSON instance.
newtype VersionRangeJSON = VersionRangeJSON { unVersionRangeJSON :: VersionRange }

-- | Parse VersionRange.
instance FromJSON VersionRangeJSON where
  parseJSON = withText "VersionRange"
                (\s -> maybe (fail ("Invalid cabal-style VersionRange: " ++ T.unpack s))
                             (return . VersionRangeJSON)
                             (Distribution.Text.simpleParse (T.unpack s)))

data ConfigException
  = ParseConfigFileException (Path Abs File) ParseException
  | ParseResolverException Text
  | NoProjectConfigFound (Path Abs Dir) (Maybe Text)
  | UnexpectedTarballContents [Path Abs Dir] [Path Abs File]
  | BadStackVersionException VersionRange
  | NoMatchingSnapshot [SnapName]
  | NoSuchDirectory FilePath
  | ParseGHCVariantException String
  deriving Typeable
instance Show ConfigException where
    show (ParseConfigFileException configFile exception) = concat
        [ "Could not parse '"
        , toFilePath configFile
        , "':\n"
        , show exception
        , "\nSee https://github.com/commercialhaskell/stack/blob/release/doc/yaml_configuration.md."
        ]
    show (ParseResolverException t) = concat
        [ "Invalid resolver value: "
        , T.unpack t
        , ". Possible valid values include lts-2.12, nightly-YYYY-MM-DD, ghc-7.10.2, and ghcjs-0.1.0_ghc-7.10.2. "
        , "See https://www.stackage.org/snapshots for a complete list."
        ]
    show (NoProjectConfigFound dir mcmd) = concat
        [ "Unable to find a stack.yaml file in the current directory ("
        , toFilePath dir
        , ") or its ancestors"
        , case mcmd of
            Nothing -> ""
            Just cmd -> "\nRecommended action: stack " ++ T.unpack cmd
        ]
    show (UnexpectedTarballContents dirs files) = concat
        [ "When unpacking a tarball specified in your stack.yaml file, "
        , "did not find expected contents. Expected: a single directory. Found: "
        , show ( map (toFilePath . dirname) dirs
               , map (toFilePath . filename) files
               )
        ]
    show (BadStackVersionException requiredRange) = concat
        [ "The version of stack you are using ("
        , show (fromCabalVersion Meta.version)
        , ") is outside the required\n"
        ,"version range ("
        , T.unpack (versionRangeText requiredRange)
        , ") specified in stack.yaml." ]
    show (NoMatchingSnapshot names) = concat
        [ "There was no snapshot found that matched the package "
        , "bounds in your .cabal files.\n"
        , "Please choose one of the following commands to get started.\n\n"
        , unlines $ map
            (\name -> "    stack init --resolver " ++ T.unpack (renderSnapName name))
            names
        , "\nYou'll then need to add some extra-deps. See:\n\n"
        , "    https://github.com/commercialhaskell/stack/blob/release/doc/yaml_configuration.md#extra-deps"
        , "\n\nYou can also try falling back to a dependency solver with:\n\n"
        , "    stack init --solver"
        ]
    show (NoSuchDirectory dir) = concat
        ["No directory could be located matching the supplied path: "
        ,dir
        ]
    show (ParseGHCVariantException v) = concat
        [ "Invalid ghc-variant value: "
        , v
        ]
instance Exception ConfigException

-- | Helper function to ask the environment and apply getConfig
askConfig :: (MonadReader env m, HasConfig env) => m Config
askConfig = liftM getConfig ask

-- | Get the URL to request the information on the latest snapshots
askLatestSnapshotUrl :: (MonadReader env m, HasConfig env) => m Text
askLatestSnapshotUrl = asks (configLatestSnapshotUrl . getConfig)

-- | Root for a specific package index
configPackageIndexRoot :: (MonadReader env m, HasConfig env, MonadThrow m) => IndexName -> m (Path Abs Dir)
configPackageIndexRoot (IndexName name) = do
    config <- asks getConfig
    dir <- parseRelDir $ S8.unpack name
    return (configStackRoot config </> $(mkRelDir "indices") </> dir)

-- | Location of the 00-index.cache file
configPackageIndexCache :: (MonadReader env m, HasConfig env, MonadThrow m) => IndexName -> m (Path Abs File)
configPackageIndexCache = liftM (</> $(mkRelFile "00-index.cache")) . configPackageIndexRoot

-- | Location of the 00-index.tar file
configPackageIndex :: (MonadReader env m, HasConfig env, MonadThrow m) => IndexName -> m (Path Abs File)
configPackageIndex = liftM (</> $(mkRelFile "00-index.tar")) . configPackageIndexRoot

-- | Location of the 00-index.tar.gz file
configPackageIndexGz :: (MonadReader env m, HasConfig env, MonadThrow m) => IndexName -> m (Path Abs File)
configPackageIndexGz = liftM (</> $(mkRelFile "00-index.tar.gz")) . configPackageIndexRoot

-- | Location of a package tarball
configPackageTarball :: (MonadReader env m, HasConfig env, MonadThrow m) => IndexName -> PackageIdentifier -> m (Path Abs File)
configPackageTarball iname ident = do
    root <- configPackageIndexRoot iname
    name <- parseRelDir $ packageNameString $ packageIdentifierName ident
    ver <- parseRelDir $ versionString $ packageIdentifierVersion ident
    base <- parseRelFile $ packageIdentifierString ident ++ ".tar.gz"
    return (root </> $(mkRelDir "packages") </> name </> ver </> base)

workDirRel :: Path Rel Dir
workDirRel = $(mkRelDir ".stack-work")

-- | Per-project work dir
configProjectWorkDir :: (HasBuildConfig env, MonadReader env m) => m (Path Abs Dir)
configProjectWorkDir = do
    bc <- asks getBuildConfig
    return (bcRoot bc </> workDirRel)

-- | File containing the installed cache, see "Stack.PackageDump"
configInstalledCache :: (HasBuildConfig env, MonadReader env m) => m (Path Abs File)
configInstalledCache = liftM (</> $(mkRelFile "installed-cache.bin")) configProjectWorkDir

-- | Relative directory for the platform identifier
platformOnlyRelDir
    :: (MonadReader env m, HasPlatform env, MonadThrow m)
    => m (Path Rel Dir)
platformOnlyRelDir = do
    platform <- asks getPlatform
    parseRelDir (Distribution.Text.display platform)

-- | Relative directory for the platform identifier
platformVariantRelDir
    :: (MonadReader env m, HasPlatform env, HasGHCVariant env, MonadThrow m)
    => m (Path Rel Dir)
platformVariantRelDir = do
    platform <- asks getPlatform
    ghcVariant <- asks getGHCVariant
    parseRelDir (Distribution.Text.display platform <> ghcVariantSuffix ghcVariant)

-- | Path to .shake files.
configShakeFilesDir :: (MonadReader env m, HasBuildConfig env) => m (Path Abs Dir)
configShakeFilesDir = liftM (</> $(mkRelDir "shake")) configProjectWorkDir

-- | Where to unpack packages for local build
configLocalUnpackDir :: (MonadReader env m, HasBuildConfig env) => m (Path Abs Dir)
configLocalUnpackDir = liftM (</> $(mkRelDir "unpacked")) configProjectWorkDir

-- | Directory containing snapshots
snapshotsDir :: (MonadReader env m, HasConfig env, HasGHCVariant env, MonadThrow m) => m (Path Abs Dir)
snapshotsDir = do
    config <- asks getConfig
    platform <- platformVariantRelDir
    return $ configStackRoot config </> $(mkRelDir "snapshots") </> platform

-- | Installation root for dependencies
installationRootDeps :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m (Path Abs Dir)
installationRootDeps = do
    snapshots <- snapshotsDir
    bc <- asks getBuildConfig
    name <- parseRelDir $ T.unpack $ resolverName $ bcResolver bc
    ghc <- compilerVersionDir
    return $ snapshots </> name </> ghc

-- | Installation root for locals
installationRootLocal :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m (Path Abs Dir)
installationRootLocal = do
    bc <- asks getBuildConfig
    name <- parseRelDir $ T.unpack $ resolverName $ bcResolver bc
    ghc <- compilerVersionDir
    platform <- platformVariantRelDir
    return $ configProjectWorkDir bc </> $(mkRelDir "install") </> platform </> name </> ghc

compilerVersionDir :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m (Path Rel Dir)
compilerVersionDir = do
    compilerVersion <- asks (envConfigCompilerVersion . getEnvConfig)
    parseRelDir $ case compilerVersion of
        GhcVersion version -> versionString version
        GhcjsVersion {} -> compilerVersionString compilerVersion

-- | Package database for installing dependencies into
packageDatabaseDeps :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m (Path Abs Dir)
packageDatabaseDeps = do
    root <- installationRootDeps
    return $ root </> $(mkRelDir "pkgdb")

-- | Package database for installing local packages into
packageDatabaseLocal :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m (Path Abs Dir)
packageDatabaseLocal = do
    root <- installationRootLocal
    return $ root </> $(mkRelDir "pkgdb")

-- | Extra package databases
packageDatabaseExtra :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m [Path Abs Dir]
packageDatabaseExtra = do
    bc <- asks getBuildConfig
    return $ bcExtraPackageDBs bc

-- | Directory for holding flag cache information
flagCacheLocal :: (MonadThrow m, MonadReader env m, HasEnvConfig env) => m (Path Abs Dir)
flagCacheLocal = do
    root <- installationRootLocal
    return $ root </> $(mkRelDir "flag-cache")

-- | Where to store mini build plan caches
configMiniBuildPlanCache :: (MonadThrow m, MonadReader env m, HasConfig env, HasGHCVariant env)
                         => SnapName
                         -> m (Path Abs File)
configMiniBuildPlanCache name = do
    root <- asks getStackRoot
    platform <- platformVariantRelDir
    file <- parseRelFile $ T.unpack (renderSnapName name) ++ ".cache"
    -- Yes, cached plans differ based on platform
    return (root </> $(mkRelDir "build-plan-cache") </> platform </> file)

-- | Suffix applied to an installation root to get the bin dir
bindirSuffix :: Path Rel Dir
bindirSuffix = $(mkRelDir "bin")

-- | Suffix applied to an installation root to get the doc dir
docDirSuffix :: Path Rel Dir
docDirSuffix = $(mkRelDir "doc")

-- | Suffix applied to an installation root to get the hpc dir
hpcDirSuffix :: Path Rel Dir
hpcDirSuffix = $(mkRelDir "hpc")

-- | Get the extra bin directories (for the PATH). Puts more local first
--
-- Bool indicates whether or not to include the locals
extraBinDirs :: (MonadThrow m, MonadReader env m, HasEnvConfig env)
             => m (Bool -> [Path Abs Dir])
extraBinDirs = do
    deps <- installationRootDeps
    local <- installationRootLocal
    return $ \locals -> if locals
        then [local </> bindirSuffix, deps </> bindirSuffix]
        else [deps </> bindirSuffix]

-- | Get the minimal environment override, useful for just calling external
-- processes like git or ghc
getMinimalEnvOverride :: (MonadReader env m, HasConfig env, MonadIO m) => m EnvOverride
getMinimalEnvOverride = do
    config <- asks getConfig
    liftIO $ configEnvOverride config minimalEnvSettings

minimalEnvSettings :: EnvSettings
minimalEnvSettings =
    EnvSettings
    { esIncludeLocals = False
    , esIncludeGhcPackagePath = False
    , esStackExe = False
    , esLocaleUtf8 = False
    }

getWhichCompiler :: (MonadReader env m, HasEnvConfig env) => m WhichCompiler
getWhichCompiler = asks (whichCompiler . envConfigCompilerVersion . getEnvConfig)

data ProjectAndConfigMonoid
  = ProjectAndConfigMonoid !Project !ConfigMonoid

instance (warnings ~ [JSONWarning]) => FromJSON (ProjectAndConfigMonoid, warnings) where
    parseJSON = withObjectWarnings "ProjectAndConfigMonoid" $ \o -> do
        dirs <- jsonSubWarningsTT (o ..:? "packages") ..!= [packageEntryCurrDir]
        extraDeps' <- o ..:? "extra-deps" ..!= []
        extraDeps <-
            case partitionEithers $ goDeps extraDeps' of
                ([], x) -> return $ Map.fromList x
                (errs, _) -> fail $ unlines errs

        flags <- o ..:? "flags" ..!= mempty
        resolver <- jsonSubWarnings (o ..: "resolver")
        config <- parseConfigMonoidJSON o
        extraPackageDBs <- o ..:? "extra-package-dbs" ..!= []
        let project = Project
                { projectPackages = dirs
                , projectExtraDeps = extraDeps
                , projectFlags = flags
                , projectResolver = resolver
                , projectExtraPackageDBs = extraPackageDBs
                }
        return $ ProjectAndConfigMonoid project config
      where
        goDeps =
            map toSingle . Map.toList . Map.unionsWith Set.union . map toMap
          where
            toMap i = Map.singleton
                (packageIdentifierName i)
                (Set.singleton (packageIdentifierVersion i))

        toSingle (k, s) =
            case Set.toList s of
                [x] -> Right (k, x)
                xs -> Left $ concat
                    [ "Multiple versions for package "
                    , packageNameString k
                    , ": "
                    , unwords $ map versionString xs
                    ]

-- | A PackageEntry for the current directory, used as a default
packageEntryCurrDir :: PackageEntry
packageEntryCurrDir = PackageEntry
    { peValidWanted = Nothing
    , peExtraDepMaybe = Nothing
    , peLocation = PLFilePath "."
    , peSubdirs = []
    }

-- | A software control system.
data SCM = Git
  deriving (Show)

instance FromJSON SCM where
    parseJSON v = do
        s <- parseJSON v
        case s of
            "git" -> return Git
            _ -> fail ("Unknown or unsupported SCM: " <> s)

instance ToJSON SCM where
    toJSON Git = toJSON ("git" :: Text)

-- | Specialized bariant of GHC (e.g. libgmp4 or integer-simple)
data GHCVariant
    = GHCStandard -- ^ Standard bindist
    | GHCGMP4 -- ^ Bindist that supports libgmp4 (centos66)
    | GHCArch -- ^ Bindist built on Arch Linux (bleeding-edge)
    | GHCIntegerSimple -- ^ Bindist that uses integer-simple
    | GHCCustom String -- ^ Other bindists
    deriving (Show)

instance FromJSON GHCVariant where
    -- Strange structuring is to give consistent error messages
    parseJSON =
        withText
            "GHCVariant"
            (either (fail . show) return . parseGHCVariant . T.unpack)

-- | Render a GHC variant to a String.
ghcVariantName :: GHCVariant -> String
ghcVariantName GHCStandard = "standard"
ghcVariantName GHCGMP4 = "gmp4"
ghcVariantName GHCArch = "arch"
ghcVariantName GHCIntegerSimple = "integersimple"
ghcVariantName (GHCCustom name) = "custom-" ++ name

-- | Render a GHC variant to a String suffix.
ghcVariantSuffix :: GHCVariant -> String
ghcVariantSuffix GHCStandard = ""
ghcVariantSuffix v = "-" ++ ghcVariantName v

-- | Parse GHC variant from a String.
parseGHCVariant :: (MonadThrow m) => String -> m GHCVariant
parseGHCVariant s =
    case stripPrefix "custom-" s of
        Just name -> return (GHCCustom name)
        Nothing
          | s == "" -> return GHCStandard
          | s == "standard" -> return GHCStandard
          | s == "gmp4" -> return GHCGMP4
          | s == "arch" -> return GHCArch
          | s == "integersimple" -> return GHCIntegerSimple
          | otherwise -> return (GHCCustom s)

-- | Information for a file to download.
data DownloadInfo = DownloadInfo
    { downloadInfoUrl :: Text
    , downloadInfoContentLength :: Maybe Int
    , downloadInfoSha1 :: Maybe ByteString
    } deriving (Show)

instance FromJSON (DownloadInfo, [JSONWarning]) where
    parseJSON = withObjectWarnings "DownloadInfo" parseDownloadInfoFromObject

-- | Parse JSON in existing object for 'DownloadInfo'
parseDownloadInfoFromObject :: Object -> WarningParser DownloadInfo
parseDownloadInfoFromObject o = do
    url <- o ..: "url"
    contentLength <- o ..:? "content-length"
    sha1TextMay <- o ..:? "sha1"
    return
        DownloadInfo
        { downloadInfoUrl = url
        , downloadInfoContentLength = contentLength
        , downloadInfoSha1 = fmap encodeUtf8 sha1TextMay
        }

data VersionedDownloadInfo = VersionedDownloadInfo
    { vdiVersion :: Version
    , vdiDownloadInfo :: DownloadInfo
    }
    deriving Show

instance FromJSON (VersionedDownloadInfo, [JSONWarning]) where
    parseJSON = withObjectWarnings "VersionedDownloadInfo" $ \o -> do
        version <- o ..: "version"
        downloadInfo <- parseDownloadInfoFromObject o
        return VersionedDownloadInfo
            { vdiVersion = version
            , vdiDownloadInfo = downloadInfo
            }

data SetupInfo = SetupInfo
    { siSevenzExe :: Maybe DownloadInfo
    , siSevenzDll :: Maybe DownloadInfo
    , siMsys2 :: Map Text VersionedDownloadInfo
    , siGHCs :: Map Text (Map Version DownloadInfo)
    , siGHCJSs :: Map Text (Map CompilerVersion DownloadInfo)
    , siStack :: Map Text (Map Version DownloadInfo)
    }
    deriving Show

instance FromJSON (SetupInfo, [JSONWarning]) where
    parseJSON = withObjectWarnings "SetupInfo" $ \o -> do
        siSevenzExe <- jsonSubWarningsT (o ..:? "sevenzexe-info")
        siSevenzDll <- jsonSubWarningsT (o ..:? "sevenzdll-info")
        siMsys2 <- jsonSubWarningsT (o ..:? "msys2" ..!= mempty)
        siGHCs <- jsonSubWarningsTT (o ..:? "ghc" ..!= mempty)
        siGHCJSs <- jsonSubWarningsTT (o ..:? "ghcjs" ..!= mempty)
        siStack <- jsonSubWarningsTT (o ..:? "stack" ..!= mempty)
        return SetupInfo {..}

-- | For @siGHCs@ and @siGHCJSs@ fields maps are deeply merged.
-- For all fields the values from the last @SetupInfo@ win.
instance Monoid SetupInfo where
    mempty =
        SetupInfo
        { siSevenzExe = Nothing
        , siSevenzDll = Nothing
        , siMsys2 = Map.empty
        , siGHCs = Map.empty
        , siGHCJSs = Map.empty
        , siStack = Map.empty
        }
    mappend l r =
        SetupInfo
        { siSevenzExe = siSevenzExe r <|> siSevenzExe l
        , siSevenzDll = siSevenzDll r <|> siSevenzDll l
        , siMsys2 = siMsys2 r <> siMsys2 l
        , siGHCs = Map.unionWith (<>) (siGHCs r) (siGHCs l)
        , siGHCJSs = Map.unionWith (<>) (siGHCJSs r) (siGHCJSs l)
        , siStack = Map.unionWith (<>) (siStack l) (siStack r) }

-- | Remote or inline 'SetupInfo'
data SetupInfoLocation
    = SetupInfoFileOrURL String
    | SetupInfoInline SetupInfo
    deriving (Show)

instance FromJSON (SetupInfoLocation, [JSONWarning]) where
    parseJSON v =
        ((, []) <$>
         withText "SetupInfoFileOrURL" (pure . SetupInfoFileOrURL . T.unpack) v) <|>
        inline
      where
        inline = do
            (si,w) <- parseJSON v
            return (SetupInfoInline si, w)

-- | How PVP bounds should be added to .cabal files
data PvpBounds
  = PvpBoundsNone
  | PvpBoundsUpper
  | PvpBoundsLower
  | PvpBoundsBoth
  deriving (Show, Read, Eq, Typeable, Ord, Enum, Bounded)

pvpBoundsText :: PvpBounds -> Text
pvpBoundsText PvpBoundsNone = "none"
pvpBoundsText PvpBoundsUpper = "upper"
pvpBoundsText PvpBoundsLower = "lower"
pvpBoundsText PvpBoundsBoth = "both"

parsePvpBounds :: Text -> Either String PvpBounds
parsePvpBounds t =
    case Map.lookup t m of
        Nothing -> Left $ "Invalid PVP bounds: " ++ T.unpack t
        Just x -> Right x
  where
    m = Map.fromList $ map (pvpBoundsText &&& id) [minBound..maxBound]

instance ToJSON PvpBounds where
  toJSON = toJSON . pvpBoundsText
instance FromJSON PvpBounds where
  parseJSON = withText "PvpBounds" (either fail return . parsePvpBounds)

-- | Provide an explicit list of package dependencies when running a custom Setup.hs
explicitSetupDeps :: (MonadReader env m, HasConfig env) => PackageName -> m Bool
explicitSetupDeps name = do
    m <- asks $ configExplicitSetupDeps . getConfig
    return $
        -- Yes there are far cleverer ways to write this. I honestly consider
        -- the explicit pattern matching much easier to parse at a glance.
        case Map.lookup (Just name) m of
            Just b -> b
            Nothing ->
                case Map.lookup Nothing m of
                    Just b -> b
                    Nothing -> False -- default value
