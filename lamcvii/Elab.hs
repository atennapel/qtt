module Elab where

import Core as C

import Prelude hiding (lookup)
import Data.List hiding (lookup, insert)
import Control.Monad
import Control.Applicative hiding (Const)
import Data.Functor
import Data.Map
import Data.Either
import Data.Maybe

import Lexer(Loc)
import Parser(Binder)
import Normalization
import Substitution
import Typechecker
import Multiplicity
import Parser
import Core(Term(..), Context)
import Elaborator
import Prettyprint

{-

  are metavariables well-typed on creation?

  new elaboration algorithm:
    - separate passes for type checking and multiplicity checking
    - produces a Result of proof states, with constraints, metavariables, guarded constants
    - maybe give up on disambiguation for a temporarily simple implementation
    
  On guarded constants:
  Take the context:
  P : Type -> Type
  f : Pi A : Type, P A -> P A
  x : B
  then the term:
  f _ x
  produces a metavariable a : Type
  and x is replaced by the guarded constant
  X : P a = x when P a = B
  
  idris/matita solution:
    equip metavariables with context
  agdalean solution:
    apply meta to variables in context, only instantiate with closed terms.
    This means more meta-variables as functions, which need to be solved appropriately
    One such instance we would like to be inferable is the motive in the case principle of
    booleans:
    
    let bool_case (P : bool -> Type)(b : Bool)(pt : P true)(pf : P false): P b =
      match b return _ with
      | true -> pt
      | false -> pf

    the _ in the motive will create a new metavariable a applied to the variables in the context,
    like so:
    
    a P b pt pf
  
    checking the motive against the expected return type produces the constraint:
    a P b pt pf b = P b
    checking the branches produces the constraints:
    a P b pt pf true = P true
    a P b pt pf false = P false
    all solvable with
    a P b pt pf = P
    we cant instantiate a with fun _ _ _ _ -> P because this term isn't closed.
    We can decide  however, since P is among a's arguments (being in the context),
    we can instantiate a with fun P _ _ _ -> P
  
  metavariables implementation is quickly crystalizing in my head
  core is polluted with:
    - metavariables, needing no context due to being applied to it.
    - guarded constants, with a type, value and set of constraints
  a final checker should ensure absense of meta's and guards as well as well-typedness of
  fully elaborated terms
    
  the elaboration algorithm is still bidirectional, inserting meta's where info is missing
  
  it will need to carry around:
    - substitution for meta's
    - constraints and the info they depend on
    
  on instantiation of meta's
    - multiplicities need to be considered, but meta's are instantiated with simple terms,
      so the should be inferrable from the bodies
    - get a grip on inferable arguments, from trivial:
        id _ 5
      or
        (fun x -> x) 5
      to inferring non-dependent motives:
        match b with | true -> false | false -> true
      to simple motives:
        (P : Bool -> Type)
        (pt : P true)
        (pf : P false)
        (b : Bool)
        match b with | true -> pt | false -> pf
      the latter is non-trivial, but solvable by picking the simplest solution to the first constraint
      motive inference becomes less important with equations though
   
  on disambiguation
  it won't do to have a search space tree only cropped at the end to blame ambiguous names for
  any error, so an appropriate data structure must be devised, satisfying the following properties:
  - once the possibilities for a name have been reduced to 1 at a certain point,
    it cannot receive blame for errors at a later point
  - when the search space is empty the guilty set of ambiguities receives blame
    errors are printed for each possible interpretation
  - when the search space is open after elaboration, the guilty set of ambiguities receives blame
    a list of possible candidates is given
  The search space must be pruned after each constraint, so that 'solved' ambiguities are
  removed from consideration.
  
  in short, the elaboration algorithm should take an open term and a proof state,
  and should return a range of possible approximated terms and their proof states updated with the 
  new constraints
-}

{- here we typecheck the abstract syntax tree (AST),
   using a basic bidirectional checking algorithm,
   also resolving variable names with type-driven name resolution
-}

convertible :: Objects -> Context -> Loc -> Term -> Term -> Elab ()
convertible glob ctx loc t0 t1 =
  if Normalization.sub glob ctx False t0 t1
  then pure ()
  else TypeError (InconvertibleTypes loc ctx t0 t1)

-- look up a qualified name in the symbol table
lookupQualified :: ElabState -> Loc -> QName -> Elab (Term,Term,Uses)
lookupQualified glob loc qname =
  case lookupQName qname glob of
    Nothing -> err (show loc ++ "unknown name: " ++ showQName qname)
    Just (_,ref) -> pure (Const (showQName qname) ref, typeofRef (globalObjects glob) ref, noUses)

-- look up a name in the symbol table and lookup Unqualified if appropriate
lookupUnqualified :: ElabState -> Loc -> Name -> Elab (Term,Term,Uses)
lookupUnqualified glob loc name = let
  in case lookupName name glob of
    Nothing -> TypeError (UnboundVar loc)
    Just [qname] -> case lookupQName qname glob of
      Nothing -> err (show loc ++ "object belonging to name not present: " ++ showQName qname)
      Just (_,ref) -> pure (C.Const name ref, typeofRef (globalObjects glob) ref, noUses)
    Just xs -> do
      mapM (\qname ->
        case lookupQName qname glob of
          Nothing -> err (show loc ++ "name not present: " ++ showQName qname)
          Just (_,ref) -> pure (qname, Clear (C.Const name ref,(typeofRef (globalObjects glob) ref), noUses))) xs >>=
        Ambiguous name loc

-- lookup a name in the context and return appropriate uses if present
lookupCtx :: Context -> Loc -> Name -> Maybe (Term,Term,Uses)
lookupCtx ctx loc name = f 0 ctx where
  f n [] = Nothing
  f n (hyp:hyps)
    | name == hypName hyp = pure (Var n, lift (n + 1) (hypType hyp), (Oneuse One loc) : noUses)
    | otherwise = fmap (\(t,ty,u) -> (t,ty,Nouse:u)) (f (n + 1) hyps)

-- check if a term is a valid sort
checkSort :: Objects -> Context -> Loc -> Term -> Elab ()
checkSort glob ctx loc x = case whd glob ctx x of
  Star -> pure ()
  Box -> pure ()
  _ -> err (show loc ++ "Invalid sort:\n" ++ showTerm ctx x)

-- check variable usage against given multiplicity
checkArgMult :: Loc -> Mult -> Use -> Elab ()
checkArgMult _ Many _ = pure ()
checkArgMult _ Zero uses = f uses where
  f Nouse           = pure ()
  f (Oneuse Zero _) = pure ()
  f (Oneuse _ loc) = TypeError (RelevantUse loc)
  f (CaseUse loc xs) = mapM_ f xs
  f (Adduse x y) = f x *> f y
checkArgMult loc One uses = checkOne uses where

  checkOne Nouse = TypeError (Unused loc)
  checkOne (Oneuse Zero _) = TypeError (Unused loc)
  checkOne (Oneuse One _) = pure ()
  checkOne (Oneuse Many loc) = TypeError (UnrestrictedUse loc)
  checkOne (Adduse x y) = do
    m <- checkMaybe x
    if m
    then checkNone y
    else checkOne y
  checkOne (CaseUse loc' xs) = mapM_ checkOne xs
  
  checkNone Nouse = pure ()
  checkNone (Oneuse Zero _) = pure ()
  checkNone (Oneuse One loc) = TypeError (MultipleUse loc)
  checkNone (Oneuse Many loc) = TypeError (UnrestrictedUse loc)
  checkNone (Adduse x y) = checkNone x *> checkNone y
  checkNone (CaseUse loc' xs) = mapM_ checkNone xs
  
  checkMaybe Nouse = pure False
  checkMaybe (Oneuse Zero _) = pure False
  checkMaybe (Oneuse One _) = pure True
  checkMaybe (Oneuse Many loc) = TypeError (UnrestrictedUse loc)
  checkMaybe (Adduse x y) = do
    m <- checkMaybe x
    if m
    then checkNone y *> pure True
    else checkMaybe y
  checkMaybe (CaseUse loc' xs) = do
    uses <- mapM checkMaybe xs
    if and uses || not (or uses)
    then pure (or uses)
    else TypeError (IntersectUse loc')

-- find the correct constructor ids for given names
identifyBranch :: ElabState -> Binder -> C.Reference -> Elab Int
identifyBranch glob bind (ref @ (IndRef obj_id defno)) =
  let name = binderName bind
      loc  = binderLoc bind in
    case lookupName name glob of
      Nothing -> err (show (binderLoc bind) ++ "constructor name not found: " ++ name)
      Just qnames -> let
          refs = mapM (\qname -> case lookupQName qname glob of
            Nothing -> err (show loc ++ "name not present: " ++ showQName qname)
            Just name -> pure name) qnames

          g ((_,ConRef obj_id' defno' constrno _): _)
            | obj_id == obj_id' && defno == defno' = pure constrno
          g (_:xs) = g xs
          g _ = TypeError (InvalidConstructor bind ref)
        in refs >>= g

-- check if every constructor of the inductive type is handled in a match expression
-- needs update for default cases
checkCovering :: Loc -> Int -> Int -> Int -> [Int] -> Elab ()
checkCovering loc obj_id defno ctor_count = f 0 where
  f n []
    | n == ctor_count = pure ()
  f n (m:ms)
    | m == n = f (n + 1) ms
  f n _ = TypeError (MissingCase loc (ConRef obj_id defno n undefined))

checkBranch :: ElabState -> Context -> Mult -> Term -> [Term] -> Int -> Int -> Int -> Int -> Term -> (Binder, [Binder], Expr) -> Elab (Term,Uses)
checkBranch glob ctx mult motive params obj_id defno pno ctorno ctor_ty (bind,args,expr) = do
  let
    ctorname = binderName bind
  
    -- drop the first n domains of a nested pi-type, to instantiate it with the inductive parameters
    drop_domains 0 tb = tb
    drop_domains n (Pi _ _ _ tb) = drop_domains (n - 1) tb

    -- specialize the type of the constructor with the inductive parameters
    instantiated_ctor_ty = psubst (reverse params) (drop_domains (length params) ctor_ty)
    
    -- compute the types and multiplicities of the arguments of the specialized constructor
    unroll (Pi m _ ta tb) (mults,tys) = unroll tb (times mult m : mults, ta : tys)
    unroll tb acc = acc
    
    (mults,arg_tys) = unroll instantiated_ctor_ty mempty
    
    -- number of arguments in the AST
    given_arity = length args
    
    -- source locations and names of arguments in the AST
    (arg_locs,arg_names) = unzip (fmap (\b -> (binderLoc b, binderName b)) (reverse args))
    
    -- actual number of arguments of the constructor, modulo parameters
    expected_arity = length arg_tys
    
    -- associate the names in the AST with the types of the arguments
    update = zipWith (\name ty -> Hypothesis name ty Nothing) arg_names arg_tys
    
    ctx' = update ++ ctx
    
    count_down n
      | n > 0 = Var (n - 1) : count_down (n - 1)
      | otherwise = []
      
    -- constructor applied to the inductive parameters and the just now introduced arguments, needed to compute the return type
    applied_ctor = App (Const ctorname (ConRef obj_id defno ctorno pno)) ((fmap (lift expected_arity) params) ++ count_down expected_arity)
    
    expected_branch_ty = App (lift expected_arity motive) [applied_ctor]
  
  if given_arity == expected_arity
  then pure ()
  else TypeError (ConstructorArity (binderLoc bind) (IndRef obj_id defno))
  
  (branch,uses) <- check glob ctx' expr expected_branch_ty
  
  let (arg_uses, uses') = Data.List.splitAt expected_arity uses
  
      abstract_branch = Data.List.foldl (\acc (m,n,t) -> Lam m n t acc)
  
  sequence_ (zipWith3 checkArgMult arg_locs mults arg_uses)
  
  pure (abstract_branch branch ((zip3 mults arg_names arg_tys)), uses')

-- check a match expression with a given motive
checkMatch :: ElabState -> Context -> Loc -> Mult -> Expr -> Term -> [(Binder,[Binder],Expr)] -> Elab (Term,Term,Uses)
checkMatch glob ctx loc mult scrutinee motive cases = do
  (scrutinee',inty,uterm) <- synth glob ctx scrutinee
  
  case mult of
    Zero -> if length cases > 1
      then err (show loc ++ "\n erased match may have at most one branch")
      else pure ()
    _ -> pure ()
  
  let
    getElimineeType :: Objects -> Context -> Loc -> Term -> Term -> Elab (Reference,[Term])
    getElimineeType glob ctx loc e t = case whd glob ctx t of
      App (Const _ (ref @ (IndRef _ _))) args -> pure (ref,args)
      Const _ (ref @ (IndRef _ _ )) -> pure (ref,[])
      _ -> err (show loc ++ showContext ctx ++ "\n expected a term of some inductive type, but the expression:\n" ++ showTerm ctx e ++ "\n is of type:\n" ++ showTerm ctx t) 

  -- get the inductive type reference and the parameters from the scrutinee
  (indref,indparams) <- getElimineeType (globalObjects glob) ctx (exprLoc scrutinee) scrutinee' inty
    
  let -- number of parameters
      pno = length indparams
      
      -- destruct reference,
      IndRef obj_id defno = indref
      
      -- get definition
      Just ind_block = Data.Map.lookup obj_id (globalInd (globalObjects glob))
      inddef = ind_block !! defno
      
      -- get constructor types
      ctor_types = introRules inddef
  
  -- from the obj_ids of the cases, find out which case belongs to which constructor
  branch_ids <- mapM (\(x,_,_) -> identifyBranch glob x indref) cases
  
  -- sort the branches to match the order of declarations of the constructors
  let tagged_branches = zip branch_ids cases
      (sorted_ids,sorted_branches) = unzip (sortOn fst tagged_branches)
  
  -- check if each constructor is accounted for
  checkCovering loc obj_id defno (length ctor_types) sorted_ids
  
  -- check the branches
  bruses <- sequence (zipWith3 (checkBranch glob ctx mult motive indparams obj_id defno pno) [0..] ctor_types sorted_branches)
  
  let (branches,usess) = unzip bruses
      uses = branchUses loc usess
      result = CaseDistinction {
        elimType = (obj_id,defno),
        elimMult = mult,
        eliminee = scrutinee',
        motive = motive,
        branches = branches}
      result_type = App motive [scrutinee']
  
  pure (Case result, result_type, plusUses (timesUses mult uterm) uses)

-- check or synthesise the binding of a let expression
checkLetBinding :: ElabState -> Context -> Binder -> Maybe Expr -> Expr -> Elab (Term,Term,Uses)
checkLetBinding glob ctx bind Nothing a = synth glob ctx a
checkLetBinding glob ctx bind (Just ta) a = do
  let la = exprLoc ta
  (ta,ka,_) <- synth glob ctx ta
  checkSort (globalObjects glob) ctx la ka
  (a,ua) <- check glob ctx a ta
  pure (a,ta,ua)

-- for the given expression, compute its corresponding core term, its type and the usage environment
synth :: ElabState -> Context -> Expr -> Elab (Term,Term,Uses)
synth glob ctx expr = case expr of
  EHole  loc -> err "Holes are not implemented"
  EType  loc -> pure (Star, Box, noUses)
  EName  loc qname -> lookupQualified glob loc qname
  EVar   loc name -> maybe (lookupUnqualified glob loc name) pure (lookupCtx ctx loc name)
  EApply loc f xs -> do
    (f,tf,uf) <- synth glob ctx f
    
    (args,tapp,uargs) <- checkArgs tf xs
    
    pure (App f args, tapp, plusUses uf uargs) where
    
      checkArgs tf [] = pure ([],tf,noUses)
      checkArgs tf (arg:args) = do
        case whd (globalObjects glob) ctx tf of
          Pi m name ta tb -> do
            (a,ua) <- check glob ctx arg ta
            (args',tb',uargs) <- checkArgs (subst a tb) args
            pure (a:args', tb', plusUses (timesUses m ua) uargs)
          x -> err (
                  show loc ++ "\n" ++
                  showContext ctx ++ "\n" ++
                  "application expected some function, but got:\n" ++
                  showTerm ctx x ++ "\n")
  ELet loc bind ta a b -> do
    (a,ta,ua) <- checkLetBinding glob ctx bind ta a
    let name = binderName bind
        hyp = Hypothesis name ta (Just a)
    (b,tb,ub0) <- synth glob (hyp : ctx) b
    let ux : ub = ub0
        u = useSum ux
    -- substitute binder in return type?
    pure (Let name ta a b, subst a tb, plusUses (timesUses u ua) ub)
  ELambda loc _ _ Nothing _ -> err (show loc ++ showContext ctx ++ "\n\ncannot infer lambda")--TypeError (SynthLambda loc)
  ELambda loc m bind (Just ta) b -> do
    let la = exprLoc ta
    (ta,ka,_) <- synth glob ctx ta
    checkSort (globalObjects glob) ctx la ka
    let name = binderName bind
        loc' = binderLoc bind
        hyp = Hypothesis {
          hypName = name,
          hypType = ta,
          hypDef  = Nothing}
    (b,tb,ub0) <- synth glob (hyp : ctx) b
    let ux : ub = ub0
    checkArgMult loc' m ux
    pure (Lam m name ta b, Pi m name ta tb, ub)
  EPi loc m bind ta tb -> do
    let la = exprLoc ta
        lb = exprLoc tb
    (ta,ka,_) <- synth glob ctx ta
    let name = maybe "" binderName bind
        hyp = Hypothesis {
          hypName = name,
          hypType = ta,
          hypDef  = Nothing}
    (tb,kb,_) <- synth glob (hyp : ctx) tb
    checkSort (globalObjects glob) ctx la ka
    checkSort (globalObjects glob) ctx lb kb
    let name = maybe "" binderName bind
    pure (Pi m name ta tb, kb, noUses)
  EMatch loc mult term motive cases -> do
    motive <- (case motive of
      Nothing -> TypeError (SynthMatch loc)
      Just motive -> pure motive)
    
    let motive_loc = exprLoc motive
 
    (motive',moty,_) <- synth glob ctx motive
    (_, ta, _) <- synth glob ctx term
    
    case whd (globalObjects glob) ctx moty of
      Pi m _ ta' tb -> do
        convertible (globalObjects glob) ctx motive_loc ta ta'
      x -> err (
              show loc ++ "\n" ++
              showContext ctx ++ "\n" ++
              "motive expected some function, but got:\n" ++
              showTerm ctx x ++ "\n")
  
    checkMatch glob ctx loc mult term motive' cases
  ELetRec loc funs a -> do
    err "nested let-recs are not implemented"

-- check an expression agains a given type and compute the corresponding core term
check :: ElabState -> Context -> Expr -> Term -> Elab (Term,Uses)
check glob ctx expr ty = case expr of
  ELambda loc _ bind Nothing b -> do
    (m, ta, tb) <- (case whd (globalObjects glob) ctx ty of
        Pi m _ ta tb -> pure (m, ta, tb)
        x -> -- TypeError (ExpectedFunction loc x))
            err (
              show loc ++
              showContext ctx ++ "\n" ++
              "(Lam-0) expected some function, but got:\n" ++
              showTerm ctx x ++ "\n"))
    let name = binderName bind
        loc' = binderLoc bind
        hyp = Hypothesis {
            hypName = name,
            hypType = ta,
            hypDef  = Nothing}
    (b,ub0) <- check glob (hyp : ctx) b tb
    let ux : ub = ub0
    checkArgMult loc' m ux
    pure (Lam (useSum ux) name ta b, ub)
  ELambda loc _ bind (Just ta) b -> do
    (ta,_,_) <- synth glob ctx ta
    let ty' = whd (globalObjects glob) ctx ty
    (m, ta', tb) <- (case ty' of
        Pi m _ ta tb -> pure (m, ta, tb)
        x -> err (
              show loc ++
              showContext ctx ++ "\n" ++
              "(@Lam) expected some function, but got:\n" ++
              showTerm ctx ty ++ "\n" ++
              showTerm ctx ty' ++ "\n"))
    let name = binderName bind
        loc' = binderLoc bind
        hyp = Hypothesis {
            hypName = name,
            hypType = ta,
            hypDef  = Nothing}
    
    if Normalization.sub (globalObjects glob) ctx False ta' ta
    then pure ()
    else
      err (show loc ++ "\n" ++
        "in context:\n" ++
        showContext ctx ++ "\n" ++
        "The argument is expected to have type:\n" ++
        showTerm ctx ty ++ "\n" ++
        "but has been given type:\n" ++
        showTerm ctx ta)
    
    (b,ub0) <- check glob (hyp : ctx) b tb
    
    (ux,ub) <- (case ub0 of
      (ux:ub) -> pure (ux,ub)
      _ -> err (show loc ++ showContext ctx ++ "\nempty usage list should be infinite"))    
    
    let ux : ub = ub0
    checkArgMult loc' m ux
    pure (Lam (useSum ux) name ta b, ub)
  ELet loc bind ta a b -> do
    (a,ta,ua) <- checkLetBinding glob ctx bind ta a
    let name = binderName bind
        hyp = Hypothesis name ta (Just a)
    (b,ub0) <- check glob (hyp : ctx) b (lift 1 ty)
    let ux : ub = ub0
        u = useSum ux
    pure (Let name ta a b, plusUses (timesUses u ua) ub)
  EMatch loc mult scrutinee Nothing branches -> do
    (_,ta,_) <- synth glob ctx scrutinee
    (t,_,u) <- checkMatch glob ctx loc mult scrutinee (Lam Many "" ta (lift 1 ty)) branches
    pure (t,u)
  x -> do
    (a,ta,ua) <- synth glob ctx x
    
    let ty' = whd (globalObjects glob) ctx ty
        ta' = whd (globalObjects glob) ctx ta
    
    if Normalization.sub (globalObjects glob) ctx False ta ty
    then pure ()
    else
      err (show (exprLoc x) ++ "\n" ++
        "in context:\n" ++
        showContext ctx ++ "\n" ++
        "expected type:\n" ++
        showTerm ctx ty' ++ "\n" ++
        "but expression:\n" ++
        showTerm ctx a ++ "\n" ++
        "has type:\n" ++
        showTerm ctx ta')
    
    pure (a,ua)

