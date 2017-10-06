{-# OPTIONS_GHC -Wall #-}
module Elm.Project.Flags
  ( Options(..)
  , Output(..)
  , safeCustomPath
  )
  where


import qualified System.Directory as Dir
import System.FilePath ((</>))

import qualified Elm.Compiler as Compiler



data Options =
  Options
    { _debug :: Bool
    , _target :: Compiler.Target
    , _output :: Maybe Output
    }


data Output
  = None
  | Custom (Maybe FilePath) FilePath


safeCustomPath :: Maybe FilePath -> FilePath -> IO FilePath
safeCustomPath maybeDirectory fileName =
  case maybeDirectory of
    Nothing ->
      do  return fileName

    Just dir ->
      do  Dir.createDirectoryIfMissing True dir
          return (dir </> fileName)
