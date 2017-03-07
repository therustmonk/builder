{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module File.Crawl
  ( Graph(..)
  , Info(..)
  , crawl
  )
  where

import Control.Concurrent.Chan (Chan, newChan, readChan)
import Control.Monad (forM_)
import Control.Monad.Except (liftIO)
import qualified Data.Graph as Graph
import qualified Data.Map as Map

import qualified Elm.Compiler as Compiler
import qualified Elm.Compiler.Module as Module
import qualified Elm.Package as Pkg

import Elm.Project (Project)
import qualified Elm.Project as Project
import qualified File.Find as Find
import qualified File.IO as IO
import qualified Reporting.Error as Error
import qualified Reporting.Error.Crawl as E
import qualified Reporting.Task as Task
import qualified Stuff.Deps as Deps



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


crawl :: FilePath -> Project -> Deps.Summary -> Task.Task Graph
crawl root project summary =
  let
    environment =
      Env
        { _root = root
        , _project = project
        , _exposed = Deps._exposed summary
        }

    unvisited =
      map (Unvisited Nothing) (Project.getRoots project)
  in
    do  graph <- dfs environment unvisited
        checkForCycles graph
        return graph



data Env =
  Env
    { _root :: FilePath
    , _project :: Project
    , _exposed :: Deps.ExposedModules
    }



-- DEPTH FIRST SEARCH


dfs :: Env -> [Unvisited] -> Task.Task Graph
dfs env unvisited =
  do  chan <- liftIO $ newChan

      graph <-
        do  mapM_ (Task.workerChan chan . crawlFile env) unvisited
            dfsHelp env chan (length unvisited) empty

      if Map.null (_problems graph)
        then return graph
        else Task.throw (Error.Crawl (_problems graph))


type FileResult = Either (Module.Raw, E.Error) Asset


dfsHelp :: Env -> Chan FileResult -> Int -> Graph -> Task.Task Graph
dfsHelp env chan pendingWork graph =
  if pendingWork == 0 then
    return graph

  else
    do  asset <- liftIO $ readChan chan
        case asset of
          Right (Local name node) ->
            do  let locals = Map.insert name node (_locals graph)
                let newGraph = graph { _locals = locals }
                let deps = filter (isNew newGraph) (_deps node)
                forM_ deps $ \dep ->
                  Task.workerChan chan $
                    crawlFile env (Unvisited (Just name) dep)
                let newPending = pendingWork - 1 + length deps
                dfsHelp env chan newPending newGraph

          Right (Native name path) ->
            do  let natives = Map.insert name path (_natives graph)
                let newGraph = graph { _natives = natives }
                let newPending = pendingWork - 1
                dfsHelp env chan newPending newGraph

          Right (Foreign name pkg vsn) ->
            do  let foreigns = Map.insert name (pkg, vsn) (_foreigns graph)
                let newGraph = graph { _foreigns = foreigns }
                let newPending = pendingWork - 1
                dfsHelp env chan newPending newGraph

          Left (name, err) ->
            do  let problems = Map.insert name err (_problems graph)
                let newGraph = graph { _problems = problems }
                let newPending = pendingWork - 1
                dfsHelp env chan newPending newGraph


isNew :: Graph -> Module.Raw -> Bool
isNew (Graph locals natives foreigns problems) name =
  Map.notMember name locals
  && Map.notMember name natives
  && Map.notMember name foreigns
  && Map.notMember name problems



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


crawlFile :: Env -> Unvisited -> Task.Task_ (Module.Raw, E.Error) Asset
crawlFile env@(Env root project exposed) (Unvisited maybeParent name) =
  Task.mapError ((,) name) $
    do  asset <- Find.find root project exposed name
        case asset of
          Find.Local path ->
            readValidHeader env name path

          Find.Native path ->
            return (Native name path)

          Find.Foreign pkg vsn ->
            return (Foreign name pkg vsn)



-- READ HEADER


type HReader a = Task.Task_ E.Error a


readValidHeader :: Env -> Module.Raw -> FilePath -> HReader Asset
readValidHeader env expectedName path =
  do  let pkg = Project.getName (_project env)
      source <- liftIO (IO.readUtf8 path)

      (tag, name, deps) <-
        -- TODO get regions on data extracted here
        case Compiler.parseDependencies pkg source of
          Right result ->
            return result

          Left msg ->
            Task.throw (E.BadHeader path msg)

      checkName path expectedName name
      checkTag (_project env) path tag

      return (Local name (Info path deps))


checkName :: FilePath -> Module.Raw -> Module.Raw -> HReader ()
checkName path expectedName actualName =
  if expectedName == actualName then
    return ()

  else
    Task.throw (E.BadName path actualName)


checkTag :: Project -> FilePath -> Compiler.Tag -> HReader ()
checkTag project path tag =
  case tag of
    Compiler.Normal ->
      return ()

    Compiler.Port ->
      case project of
        Project.App _ ->
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
