{-# OPTIONS_GHC -Wall #-}
module Elm.Publish (publish) where


import Control.Monad (when)
import Control.Monad.Except (catchError, runExceptT)
import Control.Monad.Trans (liftIO, lift)
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified System.Directory as Dir
import qualified System.Exit as Exit
import System.FilePath ((</>))
import qualified System.IO as IO
import qualified System.Process as Process

import qualified Deps.Diff as Diff
import qualified Deps.Get as Get
import qualified Deps.Website as Website
import qualified Elm.Bump as Bump
import qualified Elm.Package as Pkg
import qualified Elm.Project as Project
import qualified Elm.Project.Json as Project
import qualified Elm.Project.Summary as Summary
import qualified Reporting.Error as Error
import qualified Reporting.Progress as Progress
import qualified Reporting.Task as Task
import qualified Stuff.Paths as Path



-- PUBLISH


publish :: Summary.Summary -> Task.Task ()
publish summary@(Summary.Summary root project _ _ _) =
  case project of
    Project.App _ ->
      Task.throw Error.CannotPublishApp

    Project.Pkg (Project.PkgInfo name smry _ version exposed _ _ _ _) ->
      do
          allPackages <- Get.all Get.RequireLatest
          let maybePublishedVersions = Map.lookup name allPackages

          Task.report (Progress.PublishStart name version maybePublishedVersions)

          when (null exposed)    $ Task.throw Error.PublishWithoutExposed
          when (badSummary smry) $ Task.throw Error.PublishWithoutSummary

          verifyReadme root
          verifyLicense root
          verifyVersion summary name version maybePublishedVersions
          commitHash <- verifyTag name version
          verifyNoChanges commitHash
          zipHash <- verifyZip name version

          Website.register name version commitHash zipHash

          Task.report Progress.PublishEnd



-- VERIFY SUMMARY


badSummary :: Text.Text -> Bool
badSummary summary =
  Text.null summary || Project.defaultSummary == summary



-- VERIFY README


verifyReadme :: FilePath -> Task.Task ()
verifyReadme root =
  phase Progress.CheckReadme $
    do  let readmePath = root </> "README.md"
        exists <- liftIO $ Dir.doesFileExist readmePath
        case exists of
          False ->
            Task.throw Error.PublishWithoutReadme

          True ->
            do  size <- liftIO $ IO.withFile readmePath IO.ReadMode IO.hFileSize
                if size < 300
                  then Task.throw Error.PublishWithShortReadme
                  else return ()



-- VERIFY LICENSE


verifyLicense :: FilePath -> Task.Task ()
verifyLicense root =
  phase Progress.CheckLicense $
    do  let licensePath = root </> "LICENSE"
        exists <- liftIO $ Dir.doesFileExist licensePath
        if exists
          then return ()
          else Task.throw Error.PublishWithoutLicense



-- VERIFY GITHUB TAG


verifyTag :: Pkg.Name -> Pkg.Version -> Task.Task String
verifyTag name version =
  phase (Progress.CheckTag version) $
    Website.githubCommit name version `catchError` \_ ->
      Task.throw (Error.MissingTag version)



-- VERIFY NO LOCAL CHANGES SINCE TAG


verifyNoChanges :: String -> Task.Task ()
verifyNoChanges commitHash =
  phase Progress.CheckChanges $
    do  maybeGit <- liftIO $ Dir.findExecutable "git"
        case maybeGit of
          Nothing ->
            Task.throw (error "TODO cannot find git on your computer")

          Just git ->
            do  -- https://stackoverflow.com/questions/3878624/how-do-i-programmatically-determine-if-there-are-uncommited-changes
                exitCode <- liftIO $
                  Process.rawSystem git [ "diff-index", "--quiet", commitHash, "--" ]

                case exitCode of
                  Exit.ExitSuccess ->
                    return ()

                  Exit.ExitFailure _ ->
                    Task.throw (error "TODO local modules do not match")



-- VERIFY THAT ZIP BUILDS / COMPUTE HASH


verifyZip :: Pkg.Name -> Pkg.Version -> Task.Task Website.Sha
verifyZip name version =
  withTempDir $ \dir ->
    do  hash <- phase Progress.CheckDownload $
          Website.githubDownload name version dir

        phase Progress.CheckBuild $
          do  runner <- Task.getSilentRunner
              result <- liftIO $ Dir.withCurrentDirectory dir $ runner $
                Task.silently $ Project.generateDocs =<< Project.getRoot
              either Task.throw (\_ -> return ()) result

        return hash


withTempDir :: (FilePath -> Task.Task a) -> Task.Task a
withTempDir callback =
  do  liftIO $ Dir.createDirectoryIfMissing True Path.prepublishDir
      result <- lift $ runExceptT $ callback Path.prepublishDir
      liftIO $ Dir.removeDirectoryRecursive Path.prepublishDir
      either Task.throw return result



-- PHASE REPORTING


phase :: Progress.PublishPhase -> Task.Task a -> Task.Task a
phase publishPhase task =
  do  Task.report $ Progress.PublishProgress publishPhase Nothing

      result <- task `catchError` \err ->
        do  Task.report $ Progress.PublishProgress publishPhase (Just Progress.Bad)
            Task.throw err

      Task.report $ Progress.PublishProgress publishPhase (Just Progress.Good)

      return result



-- VERIFY VERSION


verifyVersion :: Summary.Summary -> Pkg.Name -> Pkg.Version -> Maybe [Pkg.Version] -> Task.Task ()
verifyVersion summary name version maybePublishedVersions =
  let
    reportBumpPhase bumpPhase =
      Task.report $ Progress.PublishCheckBump version bumpPhase
  in
  do  reportBumpPhase Progress.StatedVersion
      case maybePublishedVersions of
        Nothing ->
          if version == Pkg.initialVersion then
            reportBumpPhase Progress.GoodStart
          else
            Task.throw Error.NotInitialVersion

        Just publishedVersions ->
          if elem version publishedVersions then
            Task.throw $ Error.AlreadyPublished version
          else
            do  (old, magnitude) <- verifyBump summary name version publishedVersions
                reportBumpPhase (Progress.GoodBump old magnitude)

  `catchError` \err ->
    do  reportBumpPhase Progress.BadBump
        Task.throw err


verifyBump :: Summary.Summary -> Pkg.Name -> Pkg.Version -> [Pkg.Version] -> Task.Task (Pkg.Version, Diff.Magnitude)
verifyBump summary name statedVersion publishedVersions =
  let
    possibleBumps =
      Bump.toPossibleBumps publishedVersions

    isTheBump (_ ,new, _) =
      statedVersion == new
  in
  case List.find isTheBump possibleBumps of
    Nothing ->
      Task.throw $ Error.InvalidBump statedVersion (last publishedVersions)

    Just (old, new, magnitude) ->
      do  oldDocs <- Get.docs name old
          newDocs <- Task.silently (Project.generateDocs summary)
          let changes = Diff.diff oldDocs newDocs
          let realNew = Diff.bump changes old
          if new == realNew
            then
              return (old, magnitude)
            else
              Task.throw $ Error.BadBump old new magnitude realNew $
                Diff.toMagnitude changes
