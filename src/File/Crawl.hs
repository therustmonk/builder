{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module File.Crawl
  ( Graph(..)
  , Info(..)
  , crawl
  )
  where

import Control.Concurrent.Chan (Chan, newChan, readChan)
import Control.Monad (foldM, forM_)
import Control.Monad.Except (liftIO)
import qualified Data.Graph as Graph
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified Elm.Compiler as Compiler
import qualified Elm.Compiler.Module as Module
import qualified Elm.Package as Pkg

import qualified Elm.Project.Json as Project
import Elm.Project.Json (Project)
import Elm.Project.Summary (Summary(..))
import qualified File.Find as Find
import qualified File.IO as IO
import qualified Reporting.Error as Error
import qualified Reporting.Error.Crawl as E
import qualified Reporting.Task as Task



-- GRAPH


data Graph =
  Graph
    { _locals :: Map.Map Module.Raw Info
    , _natives :: Map.Map Module.Raw FilePath
    , _foreigns :: Map.Map Module.Raw (Pkg.Name, Pkg.Version)
    , _problems :: Map.Map Module.Raw E.Error
    }


data Info =
  Info
    { _path :: FilePath
    , _deps :: [Module.Raw]
    }


empty :: Graph
empty =
  Graph Map.empty Map.empty Map.empty Map.empty



-- CRAWL PROJECT


crawl :: Summary -> Task.Task Graph
crawl summary@(Summary _ project _ _) =
  let
    unvisited =
      map (Unvisited Nothing) (Project.getRoots project)
  in
    do  graph <- dfs summary unvisited
        checkForCycles graph
        return graph



-- DEPTH FIRST SEARCH


dfs :: Summary -> [Unvisited] -> Task.Task Graph
dfs summary unvisited =
  do  chan <- liftIO newChan

      graph <- dfsHelp summary chan 0 Set.empty unvisited empty

      if Map.null (_problems graph)
        then return graph
        else Task.throw (Error.Crawl (_problems graph))


type FileResult = Either (Module.Raw, E.Error) Asset


dfsHelp :: Summary -> Chan FileResult -> Int -> Set.Set Module.Raw -> [Unvisited] -> Graph -> Task.Task Graph
dfsHelp summary chan oldPending oldSeen unvisited graph =
  do  (seen, pending) <-
        foldM (crawlNew summary chan) (oldSeen, oldPending) unvisited

      if pending == 0
        then return graph
        else
          do  asset <- liftIO $ readChan chan
              case asset of
                Right (Local name info) ->
                  do  let locals = Map.insert name info (_locals graph)
                      let newGraph = graph { _locals = locals }
                      let deps = map (Unvisited (Just name)) (_deps info)
                      dfsHelp summary chan (pending - 1) seen deps newGraph

                Right (Native name path) ->
                  do  let natives = Map.insert name path (_natives graph)
                      let newGraph = graph { _natives = natives }
                      dfsHelp summary chan (pending - 1) seen [] newGraph

                Right (Foreign name pkg vsn) ->
                  do  let foreigns = Map.insert name (pkg, vsn) (_foreigns graph)
                      let newGraph = graph { _foreigns = foreigns }
                      dfsHelp summary chan (pending - 1) seen [] newGraph

                Left (name, err) ->
                  do  let problems = Map.insert name err (_problems graph)
                      let newGraph = graph { _problems = problems }
                      dfsHelp summary chan (pending - 1) seen [] newGraph


crawlNew
  :: Summary
  -> Chan FileResult
  -> (Set.Set Module.Raw, Int)
  -> Unvisited
  -> Task.Task (Set.Set Module.Raw, Int)
crawlNew summary chan (seen, n) unvisited@(Unvisited _ name) =
  if Set.member name seen then
    return (seen, n)
  else
    do  Task.workerChan chan (crawlFile summary unvisited)
        return (Set.insert name seen, n + 1)



-- DFS WORKER


data Unvisited =
  Unvisited
    { _parent :: Maybe Module.Raw
    , _name :: Module.Raw
    }


data Asset
  = Local Module.Raw Info
  | Native Module.Raw FilePath
  | Foreign Module.Raw Pkg.Name Pkg.Version


crawlFile :: Summary -> Unvisited -> Task.Task_ (Module.Raw, E.Error) Asset
crawlFile summary (Unvisited maybeParent name) =
  Task.mapError ((,) name) $
    do  asset <- Find.find summary name
        case asset of
          Find.Local path ->
            readModuleHeader summary name path

          Find.Native path ->
            return (Native name path)

          Find.Foreign pkg vsn ->
            return (Foreign name pkg vsn)



-- READ HEADER


type ATask a = Task.Task_ E.Error a


readModuleHeader :: Summary -> Module.Raw -> FilePath -> ATask Asset
readModuleHeader summary expectedName path =
  do  (name, deps) <- readHeader (_project summary) path
      checkName path expectedName name
      return (Local name (Info path deps))


readHeader :: Project -> FilePath -> ATask (Module.Raw, [Module.Raw])
readHeader project path =
  do  let pkg = Project.getName project
      source <- liftIO (IO.readUtf8 path)

      -- TODO get regions on data extracted here
      case Compiler.parseDependencies pkg source of
        Right (tag, name, deps) ->
          do  checkTag project path tag
              return (name, deps)

        Left msg ->
          Task.throw (E.BadHeader path msg)


checkName :: FilePath -> Module.Raw -> Module.Raw -> ATask ()
checkName path expectedName actualName =
  if expectedName == actualName then
    return ()

  else
    Task.throw (E.BadName path actualName)


checkTag :: Project -> FilePath -> Compiler.Tag -> ATask ()
checkTag project path tag =
  case tag of
    Compiler.Normal ->
      return ()

    Compiler.Port ->
      case project of
        Project.App _ _ ->
          return ()

        Project.Pkg _ ->
          Task.throw (E.PortsInPackage path)

    Compiler.Effect ->
      if Project.getEffect project then
        return ()

      else
        Task.throw (E.EffectsUnexpected path)



-- DETECT CYCLES


checkForCycles :: Graph -> Task.Task ()
checkForCycles (Graph locals _ _ _) =
  let
    toNode (name, info) =
      (name, name, _deps info)

    components =
      Graph.stronglyConnComp (map toNode (Map.toList locals))
  in
    mapM_ checkComponent components


checkComponent :: Graph.SCC Module.Raw -> Task.Task ()
checkComponent scc =
  case scc of
    Graph.AcyclicSCC _ ->
      return ()

    Graph.CyclicSCC names ->
      Task.throw (Error.Cycle names)
