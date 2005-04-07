module CodeGen (
  genModuleBody,
  genExports,
  genImports,
  genTodoItems,
  makeKnownSymbolsMap,
  mungeMethodInfo
  ) where

import Api
import Docs
import FormatDocs
import Marshal
import StringUtils
import ModuleScan
import MarshalFixup (cTypeNameToHSType, maybeNullParameter, maybeNullResult,
                     fixCFunctionName, leafClass, nukeParameterDocumentation)

import Prelude hiding (Enum, lines)
import List   (groupBy, sortBy, isPrefixOf, isSuffixOf, partition, find)
import Maybe  (isNothing, fromMaybe, catMaybes)
import Data.FiniteMap

import Debug.Trace (trace)

-------------------------------------------------------------------------------
-- Now lets actually generate some code fragments based on the api info
-------------------------------------------------------------------------------
genFunction :: KnownSymbols -> Bool -> Method -> Maybe FuncDoc -> Maybe MethodInfo -> ShowS
genFunction knownSymbols isConstructor method doc info =
  formattedDoc.
  ss functionName. ss " :: ". functionType. nl.
  ss functionName. sc ' '. formattedParamNames. sc '='.
  indent 1. body

  where functionName = cFuncNameToHsName (method_cname method)
	(classConstraints', paramTypes', paramMarshalers) =
	  unzip3 [ case genMarshalParameter knownSymbols (method_cname method)
                          (changeIllegalNames (cParamNameToHsName (parameter_name p)))
	                  (parameter_type p) of
                     (c, ty, m) -> (c, (ty, parameter_name p), m)
		 | p <- method_parameters method ]
	classConstraints = [ c | Just c <- classConstraints' ]
	inParamTypes = [ (paramType, lookup name paramDocMap)
                     | (InParam paramType, name) <- paramTypes' ]
	inParamNames = [ changeIllegalNames (cParamNameToHsName (parameter_name p))
		     | ((InParam _, _), p) <- zip paramTypes' (method_parameters method) ]
	outParamTypes = [ (paramType, lookup name paramDocMap)
                        | (OutParam paramType, name) <- paramTypes' ]
        formattedParamNames = cat (map (\name -> ss name.sc ' ') inParamNames)
	(returnType', returnMarshaler) =
		genMarshalResult knownSymbols (method_cname method)
                                  isConstructor (method_return_type method)
        returnType | null outParamTypes  = ("IO " ++ returnType', lookup "Returns" paramDocMap)
		   | otherwise = case unzip outParamTypes of
                                   (types', docs') ->
				     let types | returnType' == "()" = types'
				               | otherwise           = returnType' : types'
					 docs = mergeParamDocs (lookup "Returns" paramDocMap) docs'
				      in (case types of
				            [t] -> "IO " ++ t
					    ts  -> "IO (" ++ sepBy ", " types "" ++ ")"
					 ,docs)
	(outParamMarshalersBefore, outParamMarshalersAfter, returnOutParamFragments) =
             unzip3 [ genMarshalOutParameter outParamType (changeIllegalNames (cParamNameToHsName name))
                    | (OutParam outParamType, name) <- paramTypes' ]
        returnOutParams body | null outParamTypes = body
                             | otherwise = body
                                         . indent 1. ss "return (". sepBy' ", " returnOutParamFragments. ss ")"
        functionType = (case classConstraints of
	                  []  -> id
			  [c] -> ss c. ss " => "
			  cs  -> sc '('. sepBy ", " classConstraints. ss ") => ").
                       formatParamTypes (inParamTypes ++ [returnType])
	body = foldl (\body marshaler -> marshaler body)
                     call (paramMarshalers
                       ++ [ (\body -> frag. body) | frag <- reverse outParamMarshalersBefore ]
                       ++ [ (\body -> body. frag) | frag <- outParamMarshalersAfter ]
                       ++ [returnMarshaler,returnOutParams])
	call = ss (genCall (maybe (method_cname method) methodinfo_shortcname info) safety)
        safety = case info of
                  Nothing -> False
                  Just info -> methodinfo_unsafe info
        formattedDoc = haddocFormatDeclaration knownSymbols docNullsAllFixed funcdoc_paragraphs doc
        docNullsAllFixed = maybeNullResult (method_cname method)
                        || or [ maybeNullParameter (method_cname method) (cParamNameToHsName (parameter_name p))
                              | p <- method_parameters method ]
        paramDocMap = case doc of
          Nothing  -> []
          Just doc -> [ (paramdoc_name paramdoc
                        ,(if paramdoc_name paramdoc == "Returns"
                           then [DocText "returns "]
                           else [DocArg (paramdoc_name paramdoc)
                                ,DocText " - "]
                         ) ++ paramdoc_paragraph paramdoc)
                      | paramdoc <- funcdoc_params doc
		      , not $ nukeParameterDocumentation
                                (method_cname method)
                                (cParamNameToHsName (paramdoc_name paramdoc)) ]
        
        formatParamTypes :: [(String, Maybe [DocParaSpan])] -> ShowS
        formatParamTypes paramTypes = format True False paramTypes
                                             -- True to indicate first elem
                                             -- False to mean previous param had no doc
          where format _    _ []                   = id
                format True _ ((t,Nothing)    :ts) =               ss t.
                                                     format False False ts
                format True _ ((t,Just doc)   :ts) = ss "\n    ". ss t.
                                                     ss (replicate (columnIndent - length t) ' ').
                                                     ss " -- ^ ". formatDoc t doc.
                                                     format False True  ts
                format _ True  ((t, Nothing)  :ts) = ss "\n -> ". ss t.
                                                     format False False ts
                format _ False ((t, Nothing)  :ts) = ss   " -> ". ss t.
                                                     format False False ts
                format _ _     ((t, Just doc) :ts) = ss "\n -> ". ss t.
                                                     ss (replicate (columnIndent - length t) ' ').
                                                     ss " -- ^ ". formatDoc t doc.
                                                     format False True  ts
                formatDoc :: String -> [DocParaSpan] -> ShowS
                formatDoc typeName =
                    sepBy' ("\n" ++ replicate (columnIndent+5) ' ' ++  "-- ")
                  . map (sepBy " ")
                  . wrapText 3 (80 - columnIndent - 8)
                  . map (mungeWord knownSymbols docNullsAllFixed)
                  . words
                  . concatMap (haddocFormatSpan knownSymbols docNullsAllFixed)
                columnIndent = maximum [ length parmType | (parmType, _) <- paramTypes ]

mergeParamDocs :: Maybe [DocParaSpan] -> [Maybe [DocParaSpan]] -> Maybe [DocParaSpan]
mergeParamDocs doc docs =
  case catMaybes (doc:docs) of
    [] -> Nothing
    [doc] -> Just doc
    docs -> let (varNames, paramDocs) =
                  unzip [ case doc of 
                            doc@(DocArg varName : _) -> (cParamNameToHsName varName, doc)
			    _                        -> ("_", doc)
			| doc <- docs ]
		returnValName = DocLiteral ("(" ++ sepBy ", " varNames "" ++ ")")
                fixmeMessage  = DocText " {FIXME: merge return value docs} "
             in Just $ returnValName : fixmeMessage : concat paramDocs

genModuleBody :: KnownSymbols -> Object -> ModuleDoc -> ModuleInfo -> ShowS
genModuleBody knownSymbols object apiDoc modInfo =
  doVersionIfDefs (sepBy' "\n\n") $
  map adjustDeprecatedAndSinceVersion $
     sectionHeader "Interfaces"
     (genImplements object)
  ++ sectionHeader "Constructors"
     (genConstructors knownSymbols object (moduledoc_functions apiDoc) (module_methods modInfo))
  ++ sectionHeader "Methods"
     (genMethods      knownSymbols object (moduledoc_functions apiDoc) (module_methods modInfo))
  ++ sectionHeader "Properties"
     (genProperties   knownSymbols object (moduledoc_properties apiDoc))
  ++ sectionHeader "Signals"
     (genSignals      knownSymbols object (moduledoc_signals apiDoc))
  where sectionHeader name []      = []
        sectionHeader name entries =
          let header = (ss "--------------------\n-- ". ss name, ("", notDeprecated))
           in header : entries
        adjustDeprecatedAndSinceVersion (doc, (since, deprecated)) =
          (doc, (moduledoc_since apiDoc `max` since, object_deprecated object || deprecated))

-- fixup the names of the C functions we got from scaning the original modules
-- we want the fully qualified "gtk_foo_bar" rather than "foo_bar" so that the
-- names match up consistently with the ones from the API xml file.
mungeMethodInfo :: Object -> ModuleInfo -> ModuleInfo
mungeMethodInfo object modInfo =
  modInfo {
    module_methods = map (\methodInfo -> 
                       if methodinfo_cname methodInfo `elem` shortMethodNames
                         then methodInfo {
                                methodinfo_cname = prefix ++ methodinfo_cname methodInfo
                              }
                         else methodInfo) (module_methods modInfo)
  }
  where shortMethodNames = [ stripPrefix (constructor_cname constructor)
                           | constructor <- object_constructors object]
                        ++ [ stripPrefix (method_cname method)
                           | method <- object_methods object]
        stripPrefix cname | prefix `isPrefixOf` cname = drop (length prefix) cname
                          | otherwise = cname
        prefix = module_context_prefix modInfo ++ "_"

genMethods :: KnownSymbols -> Object -> [FuncDoc] -> [MethodInfo] -> [(ShowS, (Since, Deprecated))]
genMethods knownSymbols object apiDoc methodInfo = 
  [ (genFunction knownSymbols False method doc info, (maybe "" funcdoc_since doc, method_deprecated method))
  | (method, doc, info) <- methods object apiDoc methodInfo True]

methods :: Object -> [FuncDoc] -> [MethodInfo] -> Bool -> [(Method, Maybe FuncDoc, Maybe MethodInfo)]
methods object docs methodsInfo sortByExisting =
  map snd $
  sortBy (comparing fst)
  [ let (doc, docIndex) = case lookup (method_cname method) docmap of
                            Nothing -> (Nothing, endDocIndex)
                            Just (doc, index) -> (Just doc, index)
        (info,infoIndex)= case lookup (method_cname method) infomap of
                            Nothing -> (Nothing, endInfoIndex)
                            Just (info, index) -> (Just info, index)
        index | sortByExisting = (infoIndex, docIndex) --preserve order from existing module
              | otherwise      = (docIndex, infoIndex) --use gtk-doc order
     in (index,(mungeMethod object method, doc, info))
  | method <- object_methods object
  , null [ () | VarArgs <- method_parameters method]   --exclude VarArgs methods
  , not (method_deprecated method && isNothing (lookup (method_cname method) infomap)) ]
  where docmap =  [ (funcdoc_name doc, (doc,index))
                  | (doc,index) <- zip docs [1..] ]
        infomap = [ (methodinfo_cname info, (info,index))
                  | (info,index) <- zip methodsInfo [1..] ]
        endDocIndex = length docs + 1
        endInfoIndex = length methodsInfo + 1

mungeMethod :: Object -> Method -> Method
mungeMethod object method =
  let self = Parameter {
               parameter_type = object_cname object ++ "*",
               parameter_name = "self",
               parameter_isArray = False
             }
   in method {
        method_name = object_name object ++ method_name method,
        method_parameters = if method_shared method
	                      then        method_parameters method
			      else self : method_parameters method
      } 

genConstructors :: KnownSymbols -> Object -> [FuncDoc] -> [MethodInfo] -> [(ShowS, (Since, Deprecated))]
genConstructors knownSymbols object apiDoc methodsInfo =
  [ (genFunction knownSymbols True constructor doc info, (maybe "" funcdoc_since doc, notDeprecated))
  | (constructor, doc, info) <- constructors object apiDoc methodsInfo ]

constructors :: Object -> [FuncDoc] -> [MethodInfo] -> [(Method, Maybe FuncDoc, Maybe MethodInfo)]
constructors object docs methodsInfo =
  map snd $
  sortBy (comparing fst)
  [ let doc = lookup (constructor_cname constructor) docmap
        (info,infoIndex)= case lookup (constructor_cname constructor) infomap of
                            Nothing -> (Nothing, endInfoIndex)
                            Just (info, index) -> (Just info, index)
     in (infoIndex,(mungeConstructor object constructor, doc, info))
  | constructor <- object_constructors object
  , null [ () | VarArgs <- constructor_parameters constructor] ]
  where docmap  = [ (funcdoc_name doc, deleteReturnDoc doc) | doc <- docs ]
        infomap = [ (methodinfo_cname info, (info,index))
                  | (info,index) <- zip methodsInfo [1..] ]
        endInfoIndex = length methodsInfo + 1
        -- the documentation for the constructor return value is almost
        -- universally useless and pointless so remove it.
        deleteReturnDoc doc = doc { funcdoc_params = [ p | p <- funcdoc_params doc
                                                         , paramdoc_name p /= "Returns" ] }

mungeConstructor :: Object -> Constructor -> Method
mungeConstructor object constructor =
  Method {
    method_name = cFuncNameToHsName (constructor_cname constructor),
    method_cname = constructor_cname constructor,
    method_return_type = object_cname object ++ "*",
    method_parameters = constructor_parameters constructor,
    method_shared = False,
    method_deprecated = False
  }

properties :: Object -> [PropDoc] -> [(Either Property (Method, Method), Maybe PropDoc)]
properties object docs =
  map snd $
  sortBy (comparing fst) $    --sort into the order as they appear in the gtk-docs
    [ (maxBound :: Int
      ,(Right methods
       ,Just $ extraPropDocumentation getter setter))
    | methods@(getter, setter) <- extraProps ]

 ++ [ (index :: Int
      ,(Right (getter, setter)
       ,lookup (property_cname property) docmap))
    | ((property, index), (getter, setter)) <- directProps ]

 ++ [ (index :: Int
      ,(Left property
       ,lookup (property_cname property) docmap))
    | (property, index) <- genericProps ]

  where docmap = [ (map dashToUnderscore (propdoc_name doc), doc)
                 | doc <- docs ]
        dashToUnderscore '-' = '_'
        dashToUnderscore  c  =  c
        
        (genericProps, -- existing GObject properties with generic implementation
         directProps,  -- existing GObject properties but with direct implementation
         extraProps)   -- extra properties with direct implementation
          = mergeBy (\(prop, _) (method, _) ->
                      property_name prop `compare` drop 3 (method_name method))
                    (sortBy (comparing (property_name.fst)) (zip (object_properties object) [1..]))
                    (sortBy (comparing (method_name.fst)) (methodsThatLookLikeProperties object))

genProperties :: KnownSymbols -> Object -> [PropDoc] -> [(ShowS, (Since, Deprecated))]
genProperties knownSymbols object apiDoc = 
  [ let implementation = case property of
          Left property          -> genAtterFromProperty knownSymbols object property doc
          Right (getter, setter) -> genAtterFromGetterSetter knownSymbols object getter setter doc
     in (implementation
        ,(maybe "" propdoc_since doc, notDeprecated))
  | (property, doc) <- properties object apiDoc ]

extraPropDocumentation :: Method -> Method -> PropDoc
extraPropDocumentation getter setter =
  let propertyName = lowerCaseFirstChar (drop 3 (method_name getter)) in
  PropDoc {
    propdoc_name = "",
    propdoc_paragraphs = [DocParaText
                           [DocText ("'" ++ propertyName ++ "' property. See ")
                           ,DocFuncXRef (method_cname getter)
                           ,DocText " and "
                           ,DocFuncXRef (method_cname setter)]],
    propdoc_since = ""
  }

genAtter :: KnownSymbols -> Object -> Maybe PropDoc -> String -> String -> String -> String -> ShowS
genAtter knownSymbols object doc propertyName propertyType getter setter = 
  formattedDoc.
  (if leafClass (object_cname object)
     then ss propertyName. ss " :: Attr ". objectType. sc ' '. ss propertyType. nl
     else ss propertyName. ss " :: ". objectType. ss "Class self => Attr self ". ss propertyType. nl).
  ss propertyName. ss " = Attr ". 
  indent 1. ss getter.
  indent 1. ss setter
  where objectType = ss (object_name object)
        formattedDoc = haddocFormatDeclaration knownSymbols False propdoc_paragraphs doc

genAtterFromProperty :: KnownSymbols -> Object -> Property -> Maybe PropDoc -> ShowS
genAtterFromProperty knownSymbols object property doc = 
  genAtter knownSymbols object doc propertyName propertyType (getter "") (setter "")

  where propertyName = lowerCaseFirstChar (object_name object ++ property_name property)
        (propertyType, gvalueConstructor) = genMarshalProperty knownSymbols (property_type property)
        getter = ss "(\\obj -> do ". ss gvalueConstructor. ss " result <- objectGetProperty \"". ss (property_cname property). ss "\"".
                 indent 7. ss "return result)"
        setter = ss "(\\obj val -> objectSetProperty obj \"". ss (property_cname property). ss "\" (". ss gvalueConstructor. ss " val))"

genAtterFromGetterSetter :: KnownSymbols -> Object -> Method -> Method -> Maybe PropDoc -> ShowS
genAtterFromGetterSetter knownSymbols object getterMethod setterMethod doc = 
  genAtter knownSymbols object doc propertyName propertyType getter setter

  where --propertyName = cFuncNameToHsPropName (method_cname getterMethod)
        propertyName = lowerCaseFirstChar (object_name object ++ drop 3 (method_name getterMethod))
        (propertyType, _) = genMarshalResult knownSymbols (method_cname getterMethod) False
                              (method_return_type getterMethod)
        getter = cFuncNameToHsName (method_cname getterMethod)
        setter = cFuncNameToHsName (method_cname setterMethod)
--        cFuncNameToHsPropName =
--            lowerCaseFirstChar
--          . concatMap upperCaseFirstChar
--          . map fixCFunctionName
--          . tail
--          . dropWhile (/="get")
--          . filter (not.null)
--          . splitBy '_'

methodsThatLookLikeProperties :: Object -> [(Method, Method)]
methodsThatLookLikeProperties object =
  filter (uncurry checkTypes) $
  intersectBy comparingMethodName getters setters
  where getters = [ method
                  | method <- object_methods object
                  , not (method_deprecated method) 
                  , "Get" `isPrefixOf` method_name method ]
        setters = [ method
                  | method <- object_methods object
                  , not (method_deprecated method) 
                  , "Set" `isPrefixOf` method_name method ]

        comparingMethodName method1 method2 = drop 3 (method_name method1)
                                           == drop 3 (method_name method2)
        intersectBy :: (a -> a -> Bool) -> [a] -> [a] -> [(a,a)]
        intersectBy eq xs ys = [ (x,y) | x <- xs, Just y <- [find (eq x) ys] ]
        
        checkTypes getter setter =
            length (method_parameters getter) == 0
         && length (method_parameters setter) == 1
         && method_return_type setter == "void"
--         && method_return_type getter == parameter_type (method_parameters setter !! 0)

signals :: Object -> [SignalDoc] -> [(Signal, Maybe SignalDoc)]
signals object docs =
  [ (signal, canonicalSignalName (signal_cname signal) `lookup` docmap)
  | signal <- object_signals object ]
  where docmap = [ (canonicalSignalName (signaldoc_name doc), doc)
                 | doc <- docs ]

genSignals :: KnownSymbols -> Object -> [SignalDoc] -> [(ShowS, (Since, Deprecated))]
genSignals knownSymbols object apiDoc = 
  [ (genSignal knownSymbols object signal doc, (maybe "" signaldoc_since doc, notDeprecated))
  | (signal, doc) <- signals object apiDoc ] 

genSignal :: KnownSymbols -> Object -> Signal -> Maybe SignalDoc -> ShowS
genSignal knownSymbols object signal doc = 
  formattedDoc.
  ss "on". signalName. ss ", after". signalName. ss " :: ". signalType.
  ss "on".    signalName. ss " = connect_". connectCall. sc ' '. signalCName. ss " False". nl.
  ss "after". signalName. ss " = connect_". connectCall. sc ' '. signalCName. ss " True"

  where connectCall = let paramCategories' = if null paramCategories then ["NONE"] else paramCategories
                       in sepBy "_" paramCategories' . ss "__" . ss returnCategory
        -- strip off the object arg to the signal handler
        params = case signal_parameters signal of
                   (param:params) | parameter_type param == object_cname object ++ "*" -> params
                   params -> params
        (paramCategories, paramTypes) = unzip [ convertSignalType knownSymbols (parameter_type parameter)
                                              | parameter <- params ]
        (returnCategory, returnType) = convertSignalType knownSymbols (signal_return_type signal)
        signalType = ss (object_name object). ss "Class self => self\n".
                     ss " -> ". (if null paramTypes
                                  then ss "IO ". ss returnType
                                  else sc '('. sepBy " -> " (paramTypes ++ ["IO " ++ returnType]). sc ')').
                     ss "\n -> IO (ConnectId self)\n"
        signalName = ss (toStudlyCaps . canonicalSignalName . signal_cname $ signal)
        signalCName = sc '"'. ss (signal_cname signal). sc '"'
        formattedDoc = haddocFormatDeclaration knownSymbols False signaldoc_paragraphs doc

genImplements :: Object -> [(ShowS, (Since, Deprecated))]
genImplements object = 
  [ (genImplement object implement, ("", notDeprecated))
  | implement <- object_implements object ] 

genImplement object implements =
  ss "instance ".ss (cTypeNameToHSType implements). ss "Class ". ss (object_name object)

canonicalSignalName :: String -> String
canonicalSignalName = map dashToUnderscore
  where dashToUnderscore '-' = '_'
        dashToUnderscore  c  =  c

makeKnownSymbolsMap :: API -> KnownSymbols
makeKnownSymbolsMap api =
   (listToFM
  . reverse
  . concat)
  [ [ (enum_cname enum
      ,case enum_variety enum of
        EnumVariety -> SymEnumType EnumKind
        FlagsVariety -> SymEnumType FlagsKind)
    | enum <- namespace_enums namespace ]
 ++ [ (object_cname object, objectKind object)
    | object <- namespace_objects namespace ]
 ++ [ (member_cname member, SymEnumValue)
    | enum <- namespace_enums namespace
    , member <- enum_members enum ]
 ++ [ (misc_cname misc, miscToCSymbol misc )
    | misc <- namespace_misc namespace ]
  | namespace <- api ]

        -- find if an object inherits via GtkObject or directly from GObject
  where objectKind :: Object -> CSymbol
        objectKind object | "GObject" `elem` parents = SymObjectType parents
                          | otherwise                = SymStructType
          where parents = objectParents object
        objectParents :: Object -> [String]
        objectParents object = object_cname object :
          case object_parent object `lookup` objectMap of
            Nothing -> [object_parent object]
            Just parent -> objectParents parent
        objectMap :: [(String, Object)]
        objectMap = [ (object_cname object, object)
                    | namespace <- api
                    , object <- namespace_objects namespace ]
        miscToCSymbol (Struct   _ _) = SymStructType
        miscToCSymbol (Boxed    _ _) = SymBoxedType
        miscToCSymbol (Class    _ _) = SymClassType
        miscToCSymbol (Alias    _ _) = SymTypeAlias
        miscToCSymbol (Callback _ _) = SymCallbackType

genExports :: Object -> ModuleDoc -> ModuleInfo -> ShowS
genExports object docs modInfo =
    doVersionIfDefs lines
  . map adjustDeprecatedAndSinceVersion
  $  [(ss "-- * Types", defaultAttrs)
     ,(ss "  ".ss (object_name object).sc ',', defaultAttrs)
     ,(ss "  ".ss (object_name object).ss "Class,", defaultAttrs)
     ,(ss "  ".ss "castTo".ss (object_name object).sc ',', defaultAttrs)] 
  ++ (sectionHeader "Constructors"
    . map fst
    . sortBy (comparing snd))
     [ let constructorName = cFuncNameToHsName (method_cname constructor) in
       ((ss "  ". ss constructorName. sc ','
       ,(maybe "" funcdoc_since doc, notDeprecated))
       ,fromMaybe (maxBound::Int) (lookup constructorName exportIndexMap))
     | (constructor, doc, _) <- constructors object (moduledoc_functions docs) []]
  ++ (sectionHeader "Methods"
    . map fst
    . sortBy (comparing snd))
     [ let functionName = cFuncNameToHsName (method_cname method) in
       ((ss "  ". ss functionName. sc ','
       ,(maybe "" funcdoc_since doc, method_deprecated method))
       ,fromMaybe (maxBound::Int) (lookup functionName exportIndexMap))
     | (method, doc, _) <- methods object (moduledoc_functions docs)
                             (module_methods modInfo) False]
  ++ sectionHeader "Properties"
     [ (let propertyName = either property_name (drop 3.method_name.fst) property in
        ss "  ". ss (lowerCaseFirstChar (object_name object ++ propertyName)). sc ','
       ,(maybe "" propdoc_since doc, notDeprecated))
     | (property, doc) <- properties object (moduledoc_properties docs)]
  ++ (sectionHeader "Signals"
    . map fst
    . sortBy (comparing snd))
     [ let signalName = (toStudlyCaps . canonicalSignalName . signal_cname) signal in 
       ((ss "  on".    ss signalName. sc ','.nl.
        ss "  after". ss signalName. sc ','
       ,(maybe "" signaldoc_since doc, notDeprecated))
       ,fromMaybe (maxBound::Int) (lookup ("on"++signalName) exportIndexMap))
     | (signal, doc) <- signals object (moduledoc_signals docs)]

  where defaultAttrs = ("", notDeprecated)
        sectionHeader name []      = []
        sectionHeader name entries = (id, defaultAttrs):(ss "-- * ". ss name, defaultAttrs):entries
        adjustDeprecatedAndSinceVersion (doc, (since, deprecated)) =
          (doc, (moduledoc_since docs `max` since, object_deprecated object || deprecated))
        exportIndexMap = zip (module_exports modInfo) [1..]

genImports :: ModuleInfo -> ShowS
genImports modInfo = 
  (case [ ss importLine
        | (importModule, importLine) <- stdModules ] of
     []   -> id
     mods -> lines mods. ss "\n\n").
  lines [ ss importLine
        | (importModule, importLine) <- extraModules ]
  where (stdModules, extraModules)
          | null (module_imports modInfo) =
             ([(undefined, "import Monad\t(liftM)")]
             ,[(undefined, "import System.Glib.FFI")
             ,(undefined, "{#import Graphics.UI.Gtk.Types#}")
             ,(undefined, "-- CHECKME: extra imports may be required")])
          | otherwise = partition (\(mod, _) -> mod `elem` knownStdModules)
                                  (module_imports modInfo)
        knownStdModules = ["Maybe", "Monad", "Char", "List", "Data.IORef"]

genTodoItems :: Object -> ShowS
genTodoItems object =
  let varargsFunctions = 
        [ ss (constructor_cname constructor)
        | constructor <- object_constructors object
        , not $ null [ () | VarArgs <- constructor_parameters constructor] ]
       ++
        [ ss (method_cname method)
        | method <- object_methods object
        , not $ null [ () | VarArgs <- method_parameters method] ]
   in if null varargsFunctions
        then id
        else nl. comment.
             ss "TODO: the following varargs functions were not bound\n".
             lines (map (ss "--   ".) varargsFunctions).
             ss "\n--"

type Deprecated = Bool
notDeprecated = False

doVersionIfDefs :: ([ShowS] -> ShowS) -> [(ShowS, (Since, Deprecated))] -> ShowS
doVersionIfDefs lines =
    lines
  . map (\group@((_,(since, deprecated)):_) ->
             sinceVersion since
           . ifdefDeprecated deprecated
           $ (lines (map fst group)))
  . groupBy (\(_,a) (_,b) -> a == b)
 
sinceVersion :: Since -> ShowS -> ShowS
sinceVersion [major,'.',minor] body =
  ss "#if GTK_CHECK_VERSION(". sc major. ss ",". sc minor. ss ",0)\n".
  body.
  ss "\n#endif"
sinceVersion _ body = body

ifdefDeprecated :: Deprecated -> ShowS -> ShowS
ifdefDeprecated True body =
  ss "#ifndef DISABLE_DEPRECATED\n".
  body.
  ss "\n#endif"
ifdefDeprecated _ body = body

comparing :: (Ord a) => (b -> a) -> b -> b -> Ordering
comparing p x y = compare (p x) (p y)