module Elab where

import Core as C

import Prelude hiding (lookup)
import Data.List hiding (lookup, insert)
import Control.Monad
import Control.Applicative
import Data.Functor
import Data.Map
import Data.Either
import Data.Maybe

import Multiplicity
import Parser
import Core(Term(..), Context, Error(..))

{-
The high-level language must provide:
  a map from qualified variables to (Info, Object)
  a map from unqualified variables to sets of candidate objects
  
Name resolution:
  Checking for each candidate seems expensive, but explore anyway:
    synthesis may now yield a set of types for a variable
    multiple variables yield greater sets.
    an unambiguous term should yield a singleton
    we can check agains each of these
    given an ambiguity, we must identify the culprit variables
    a type set is a product of the variations of each ambiguous variable
    local variables may shadow globals and take precedence, so the context remains untouched
    a set of possibilities is either a singleton or a given variable with a map to possibilities
    
    options are:
      unqualified
      qualified under current context
      fully qualified

Consider some decidable holes:
  - must be in argument position
  - therefore checkable, not synthesizable
  - when checking a hole agains a type, make fresh variable with that type
  - instantiate dependent function with that variable
  - when checking a term agains a hole, convertitability should produce a substitution
  
Solution: (Match should be annotated)
  bottom up, collect uses and availability, derive latter from uses and context

-}

data UseInfo
  = UEmpty
  | UVar  Info
  | UPlus UseInfo UseInfo
  | UMult Mult UseInfo

type Uses = [UseInfo]

data ElabError
  -- core
  = CoreError C.Error
  -- namespace errors
  | NameAlreadyDefined QName Info
  | NoSuitableDefinition Info
  -- type errors
  | ExpectedFunction Info Term
  | SynthHole Info
  | SynthLambda Info
  | UnboundVar Info  
  -- multiplicity errors
  | RelevantUseOfErased Info -- erased argument used once or unrestrictedly
  | VariableAlreadyUsed Info -- linear variable already used once
  | VariableUsedUnrestrictedly Info -- linear variable in unrestricted context

data Result a
  = Clear a
  | TypeError ElabError
  | Ambiguous Info [(QName, Result a)]

instance Functor Result where
  fmap f (TypeError err) = TypeError err
  fmap f (Clear x) = Clear (f x)
  fmap f (Ambiguous i xs) = Ambiguous i (fmap (\(n,x) -> (n,fmap f x)) xs)

instance Applicative Result where
  pure = Clear
  
  (TypeError err) <*> x = TypeError err
  (Clear f) <*> x = fmap f x
  (Ambiguous i fs) <*> x = Ambiguous i (fmap (\(n,f) -> (n, f <*> x)) fs)
  
instance Monad Result where
  return = pure
  
  (TypeError err)  >>= f = TypeError err
  (Clear x)        >>= f = f x
  (Ambiguous i xs) >>= f = Ambiguous i (fmap (\(n,x) -> (n, x >>= f)) xs)

compress :: Result a -> Result a
compress (Ambiguous i xs) = let
  xs' = Data.List.foldr (\(n,x) acc -> case compress x of
    TypeError _ -> acc
    x -> (n,x) : acc) [] xs
  in case xs' of
    []      -> TypeError (NoSuitableDefinition i)
    [(_,x)] -> x
    xs      -> Ambiguous i xs
compress x = x

compressM :: Result a -> (a -> Result b) -> Result b
compressM (TypeError err)  f = TypeError err
compressM (Clear x)        f = f x
compressM (Ambiguous i xs) f = let
  xs' = Data.List.foldr (\(n,x) acc -> case compressM x f of
    TypeError _ -> acc
    x -> (n,x) : acc) [] xs
  in case xs' of
    []      -> TypeError (NoSuitableDefinition i)
    [(_,x)] -> x
    xs      -> Ambiguous i xs
    

data ElabState = ElabState {
  freshNames  :: Int,
  freshVars   :: Int,
  elabSymbols :: Map Name [(QName, C.Reference)],
  fullSymbols :: Map QName (Info, C.Reference),
  elabGlobals :: C.Globals}

{-
  how to elaborate while disambiguating:
  1 do step 1
  2 if 1 fails, fail
  3 if step 1 produces singleton, continue as normal
  4 if step 1 produces ambiguity, fold over candidates:
    1 ok -> ok
    2 typeError -> empty ambiguous
    3 other error -> error

-}

newtype Elab a = Elab (Context -> ElabState -> Either ElabError (ElabState, Result a))

instance Functor Elab where
  fmap f (Elab g) = Elab (\ctx st -> case g ctx st of
    Left err -> Left err
    Right (st',x) -> Right (st', fmap f x))

instance Applicative Elab where
  pure x = Elab (\ctx st -> Right (st, Clear x))
  (Elab f) <*> (Elab g) = Elab (\ctx st -> case f ctx st of
    Left err -> Left err
    Right (st', f') -> case g ctx st' of
      Left err -> Left err
      Right (st'', g') -> Right (st'', f' <*> g'))

instance Alternative Elab where
  empty = undefined
  (Elab f) <|> (Elab g) = Elab (\ctx st ->
    case f ctx st of
      Left _ -> g ctx st
      x -> x)

instance Monad Elab where
  return = pure
  
  (Elab f) >>= g = Elab (\ctx st -> f ctx st >>= bar ctx) where
    bar ctx (st,x) = case x of
      TypeError err -> Right (st,TypeError err)
      Clear x -> let (Elab g') = g x in g' ctx st
      Ambiguous i xs -> do
        (st,xs') <- (Data.List.foldr (\(n,x) acc -> do
          (st,xs) <- acc
          (st',x') <- bar ctx (st,x)
          pure (st',(n,x'):xs)) (pure (st,[])) xs)
        pure (st, Ambiguous i xs')

{- PUT IN ENVIRONMENT -}

{- some context operations
  push/pop
  multiply
  redefine: variable eliminee's in case distinctions must reduce to their parameters
uses operations
  push/pop
  update
/context ops -}

get :: Elab ElabState
get = Elab (\ctx st -> Right (st, Clear st))

put :: ElabState -> Elab ()
put st = Elab (\ctx st -> Right (st, Clear ()))

typeError :: ElabError -> Elab a
typeError err = Elab (\ctx st -> Right (st, TypeError err))

fatalError :: ElabError -> Elab a
fatalError = Elab . const . const . Left

lookup_ f qname =
  maybe (error (show qname ++ "invalid context, name not found")) id .
  Data.Map.lookup qname .
  f <$> get
  
lookupName :: Name -> Elab [(QName,C.Reference)]
lookupName = lookup_ elabSymbols

lookupQName :: QName -> Elab (Info,C.Reference)
lookupQName = lookup_ fullSymbols

getInfo :: QName -> Elab Info
getInfo = fmap fst . lookupQName

getObject f i = do
  obs <- f . elabGlobals <$> get
  case lookup i obs of
    Nothing -> error "invalid global environment, missing object"
    Just item -> pure item

getContext :: Elab Context
getContext = Elab (\ctx st -> Right (st, Clear ctx))

freshId :: Elab Int
freshId = do
  st <- get
  let i = freshNames st
  put (st {freshNames = i + 1})
  pure i

ensureUndefined :: [String] -> Elab ()
ensureUndefined qname = do
  item <- Data.Map.lookup qname . fullSymbols <$> get
  case item of
    Nothing -> pure ()
    Just (info,x) -> fatalError (NameAlreadyDefined qname info)

addGlobal :: (C.Globals -> C.Globals) -> Elab ()
addGlobal f = do
  st <- get
  put (st {elabGlobals = f (elabGlobals st)})

addInductive :: Int -> C.Inductive -> Elab ()
addInductive v x = addGlobal (\obs -> obs {globalInd = insert v x (globalInd obs)})

addFixpoint :: Int -> C.Fixpoint -> Elab ()
addFixpoint v x = addGlobal (\obs -> obs {globalFix = insert v x (globalFix obs)})

addDefinition :: Int -> C.Definition -> Elab ()
addDefinition v x = addGlobal (\obs -> obs {globalDef = insert v x (globalDef obs)})

addDeclaration :: Int -> C.Declaration -> Elab ()
addDeclaration v x = addGlobal (\obs -> obs {globalDecl = insert v x (globalDecl obs)})

typeofRef :: C.Reference -> Elab Term
typeofRef ref = case ref of
  IndRef i     -> getObject globalInd i <&> indSort
  FixRef i _ _ -> getObject globalFix i <&> fixType
  ConRef i j   -> getObject globalInd i <&> (\i -> introRules i !! j)
  DefRef i _   -> getObject globalDef i <&> (\(ty,_,_) -> ty)
  DeclRef i    -> getObject globalDecl i

convertible = undefined

noUses :: Uses
noUses = repeat UEmpty

disambiguate :: Info -> Name -> Elab (Term,Term,Uses)
disambiguate info name = do
  item <- lookup name . elabSymbols <$> get
  case item of
    Nothing -> fatalError (UnboundVar info)
    Just [] -> error "empty symbol table entry"
    Just [(_,x)] -> do
      ty <- typeofRef x
      pure (C.Const info x,ty,noUses)
    Just xs -> do
      xs' <- mapM (\(name,ref) -> do
        ty <- typeofRef ref
        pure (name, Clear (C.Const info ref,ty, noUses))) xs
      Elab (\ctx st -> Right (st, Ambiguous info xs'))
      
useLocal :: Info -> Name -> Elab (Term,Term,Uses)
useLocal info name = getContext >>= f 0 where
  f n [] = fatalError (UnboundVar info)
  f n (hyp:hyps)
    | name == hypName hyp = pure (UVar info : fmap (const UEmpty) hyps, Var info n, hypType hyp)
    | otherwise = do
      (uses,t,ty) <- f (n + 1) hyps
      pure (UEmpty : uses, t, ty)


withContext :: (Context -> Context) -> Elab a -> Elab a
withContext f (Elab g) = Elab (\ctx st -> g (f ctx) st)

pushContext :: Hypothesis -> Elab a -> Elab a
pushContext hyp (Elab f) = Elab (\ctx -> f (hyp:ctx))

sortOf :: Term -> Elab Term
sortOf (Sort _ l)      = pure (Sort Nothing (l + 1))
sortOf (Pi _ _ _ _ tb) = pure (sortOf tb)
sortOf (Const ref)     = sortOf <$> typeofRef

checkPi :: Term -> Term -> Elab ()
checkPi ta tb = undefined
  

synth :: Expr -> Elab (Term,Term,Uses)
synth expr = case expr of
  EHole  info _ -> fatalError (SynthHole info)
  EType  info level -> pure (Sort info level, Sort info (level + 1), noUses)
  EVar   info name -> useLocal info name <|> disambiguate info name
  EApply info f a -> do
    (f,tf,uf) <- synth f
    (info', m, ta, tb) <- (case tf of
      Pi info m _ ta tb -> (info,m,ta,tb)
      x -> typeError (ExpectedFunction info x))
    (a,ua) <- check a
    pure (App info f a, subst a tb, zipWith UPlus uf (fmap (UMult m) ua))
  ELet info name ta a b -> do
    (a,ta,ua) <- (case ta of
      Nothing -> synth a
      Just ta -> do
        (ta,ka,_) <- synth ta
        (a,ua) <- check a ta
        pure (a,ta,ua))
    let hyp = Hypothesis {
      hypName = binderName name,
      hypMult = Many,
      hypType = ty,
      hypDef  = Just term}
    (b,tb,(ux:ub)) <- pushContext hyp (synth b)
    {- ATTENTION -}
    pure (Let info (mult ua ux) name ta a b, tb, zipWith UPlus ub (fmap (UMult Many))
  ELambda info _ _ Nothing _ -> fatalError (SynthLambda info)
  ELambda info m bind (Just ta) b -> do
    (ta,ka,_) <- synth ta
    let name = binderName bind
        hyp = Hypothesis {
          hypName = name,
          hypMult = mult,
          hypType = ty,
          hypDef  = Nothing}
    (b,tb,(ux:ub)) <- pushContext hyp (synth b)
    checkPi ta tb
    checkArgMult name m ux
    pure (Lam info m name ta b, Pi Nothing m name ta tb, ub)
    
    (m,ty,k) <- withContext (timesContext Zero) (synth ty)
    let hyp = Hypothesis {
      hypName = binderName name,
      hypMult = mult,
      hypType = ty,
      hypDef  = Nothing}
    (n,body,bodyty) <- pushContext hyp (synth body)
    undefined
    
    
    
    

subst :: Term -> Term -> Term
subst = undefined

check :: Expr -> Term -> Elab (Mult,Term)
check = undefined
 

{-


{- /IN ENVIRONMENT -}

{- IN REDUCTION -}


{- /IN REDUCTION -}

{-
  find variable in context,
  otherwise globally,
  otherise in some namespace,
  invent some conflict resolution
-}

-}

{-



-}

{-
  consider nested fixpoints as well
elabFixpoint :: [Function] -> Elab ()
elabFixpoint funs = do
  let (infos, binders, tys, bodies) = unzip4 funs
      
      names = binderName <$> binders
      
  mapM_ ensureUndefined ((:[]) <$> names)
  
  tys' <- mapM (fmap fst . synth) tys
  
  let makeContext name ty = (Many, name, ty, Nothing)
      
      context = zipWith makeContext names tys'

  bodies' <- withContext (const context) (mapM (uncurry check) (zip bodies tys'))
  
  id <- freshId
  
  undefined
  {- 
    non-mutual induction/recursion by eliminators is now officially a thing:
    - take mutually recursive definitions apart
    - find recursive parameter and compute IH
    - lift out calls nested in case expressions
    - translate matches to eliminators
    
    on eliminators:
    - account for sorts
    - account for multiplicity
      - ensure at most one (valid) case for erased arguments
        - count cases
      - ensure linear functions don't use both subdata and IH
        - keep tags on subdata for elimination expression
  
  termination check
    goal: find recursive parameters for each function
    traverse bodies
    annotate context variables:
      number of direct parameter,
      number of substructures
    analyse calls to fp:
      first order:
        find indices of smaller parameters
      second order:  
  -}

elabConstant :: Info -> Binder -> Maybe Expr -> Expr -> Elab()
elabConstant span bind ty body = do
  let name = [binderName bind]
  ensureUndefined name
  (body',ty') <- (case ty of
    Nothing -> synth body
    Just ty -> do
      (ty',_) <- synth ty
      body' <- check body ty'
      pure (body', ty'))
  id <- freshId
  insertDefinition id (C.Constant span ty' body')


elabPostulate :: Info -> Binder -> Expr -> Elab ()
elabPostulate span bind ty = do
  let name = [binderName bind]
  ensureUndefined name
  (ty',_) <- synth ty
  id <- freshId
  insertPostulate id (C.Postulate span ty')

elabModule :: Module -> Elab ()
elabModule = mapM_ elabDecl where

  elabDecl :: Decl -> Elab ()
  elabDecl (Inductive types)            = elabInductive types
  elabDecl (Fixpoint funs)              = elabFixpoint funs
  elabDecl (Constant span name ty body) = elabConstant span name ty body
  elabDecl (Postulate span name ty)     = elabPostulate span name ty
-}