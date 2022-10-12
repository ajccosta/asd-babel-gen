{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
module Typechecker where

-- TODO: Really, we should only do this after passing through an initial desugaring phase into another intermediate representation.
-- Since it doesn't really matter in the long term, I'll just accept this mess

import Data.Coerce
import qualified Data.Char as C
import qualified Data.Set as S
import qualified Data.Map as M

import Data.Functor.Foldable
import Data.Bifunctor

import Control.Monad
import Control.Monad.Identity
import Control.Monad.Except
import Control.Monad.Trans.Except
import Control.Monad.State
import Control.Monad.RWS.CPS

import Syntax

type Infer = RWS REnv [Constraint] Uniq
type REnv = [M.Map Identifier AType]
type Constraint = (AType, AType)
newtype Uniq = Uniq Int

-- No longer possible to make multi-module compilation more straightforward
-- since it handles interfaces at the beginning differently
-- typecheck :: Algorithm Parsed -> Either TypeError (Algorithm Typed)
-- typecheck alg = case runInfer (inferAlg alg) of
--   (alg', constraints) -> flip applySubst alg' <$> solve constraints

typecheckProtocols :: [Algorithm Parsed] -> Either TypeError [Algorithm Typed]
typecheckProtocols ps = case evalRWS m mempty (Uniq 0) of
  (ps', constraints) -> flip applySubst ps' <$> solve constraints
  where
    m :: Infer [Algorithm Typed]
    m = do
      let (requests, indications) = bimap concat concat $ unzip $ map ((\(InterfaceD () reqs inds) -> (reqs, inds)) . interfaceD) ps

      reqVars <- forM requests $
        \(FLDecl r args) -> (r,) . TVoidFun <$> mapM (\(Arg _ t) -> do
            v <- TVar <$> fresh
            case t of
              Nothing -> pure v
              Just t' -> constraint t' v >> pure v) args

      indVars <- forM indications $
        \(FLDecl i args) -> (i,) . TVoidFun <$> mapM (\(Arg _ t) -> do
            v <- TVar <$> fresh
            case t of
              Nothing -> pure v
              Just t' -> constraint t' v >> pure v) args

      pushScope (reqVars <> indVars) $ mapM inferAlg ps

expType :: Expr Typed -> AType
expType = cata \case
  BottomF -> TNull
  IF _ -> TInt
  BF _ -> TBool
  IdF t _ -> t
  InF _ _ -> TBool
  NotInF _ _ -> TBool
  EqF _ _ -> TBool
  NotEqF _ _ -> TBool
  SetF t _ -> TSet t
  MapF _ m -> error "type map"
  UnionF t _ _ -> TSet t
    -- TODO: Only works for sets yet, but should also work for maps.
  DifferenceF t _ _ -> TSet t
    -- TODO: Only works for sets yet, but should also work for maps.

inferAlg :: Algorithm Parsed -> Infer (Algorithm Typed)
inferAlg (P i (StateD _ vars) tops) = do
  freshTVars <- mapM (const (TVar <$> fresh)) vars
  unknownTops <- filterM (\(topIdent -> t) -> findInEnv t >>= pure . maybe True (const False)) tops
  freshUTopTVars <- mapM (const (TVar <$> fresh)) unknownTops
  topsT <- pushScope (zip vars freshTVars <> zip (map topIdent unknownTops) freshUTopTVars) $ mapM inferTop tops
  i' <- inferInterface i
  pure (P i' (StateD freshTVars vars) topsT)
    where
      topIdent :: TopDecl Parsed -> Identifier
      topIdent = \case
        UponD _ (FLDecl n _) _ -> n
        UponReceiveD _ n _ _   -> n

inferInterface :: InterfaceD Parsed -> Infer (InterfaceD Typed)
inferInterface (InterfaceD () reqs inds) = do
  reqTs <- forM reqs $ \(FLDecl r _) -> findInEnv r >>= maybe (error ("couldn't find interface request " <> r)) pure
  indTs <- forM inds $ \(FLDecl i _) -> findInEnv i >>= maybe (error ("couldn't find interface indication " <> i)) pure
  pure $ InterfaceD (reqTs, indTs) reqs inds

inferTop :: TopDecl Parsed -> Infer (TopDecl Typed)
inferTop = \case

  UponReceiveD _ name args stmts -> do
      freshTVarsOrTypes <- mapM (\(Arg _ t) -> maybe (TVar <$> fresh) pure t) (drop 1 args)
      let argsTypes = TClass "Host":freshTVarsOrTypes
      stmtsT <- pushScope (zipWith (\(Arg n _) t -> (n,t)) args argsTypes) $ mapM inferStmt stmts
      findInEnv name >>= \case
        Nothing -> error $ "Not in scope" <> name
        Just funT -> constraint funT (TVoidFun argsTypes)
      pure (UponReceiveD argsTypes name args stmtsT)

  UponD _ (FLDecl name args) stmts -> do
      freshTVars <- mapM (\(Arg _ t) -> maybe (TVar <$> fresh) pure t) args
      stmtsT <- pushScope (zipWith (\(Arg n _) t -> (n,t)) args freshTVars) $ mapM inferStmt stmts
      findInEnv name >>= \case
        Nothing -> error $ "Not in scope" <> name
        Just funT -> constraint funT (TVoidFun freshTVars)
      pure (UponD freshTVars (FLDecl name args) stmtsT)

inferStmt :: Statement Parsed -> Infer (Statement Typed)
inferStmt = cata \case
  AssignF i e -> do
    (t, e') <- inferExp e
    findInEnv i >>= \case
      Nothing -> error $ "couldn't find " <> i <> " to assign to"
      Just it -> constraint it t
    pure (Assign i e')

  IfF e thenS elseS -> do
    (t, e') <- inferExp e
    constraint t TBool
    thenS' <- sequence thenS
    elseS' <- sequence elseS
    pure (If e' thenS' elseS')
 
  TriggerSendF name args -> do

      (argTys, args') <- unzip <$> mapM inferExp args
      findInEnv name >>= \case
        Nothing   -> error $ "Couldn't find " <> name <> " in Send Trigger"
        Just funT -> constraint funT (TVoidFun argTys)
      pure (TriggerSend name args')

  TriggerF (FLCall name args) -> do
      (argTys, args') <- unzip <$> mapM inferExp args
      findInEnv name >>= \case
        Nothing -> pure () -- If name isn't found it is a notification and don't add any extra constraint
        Just funT -> constraint funT (TVoidFun argTys)
      pure (Trigger (FLCall name args'))

  ForeachF _ name e body -> do
    nt <- TVar <$> fresh
    (t, e') <- inferExp e
    constraint t (TSet nt)
    bodyT <- pushScope [(name, nt)] $ sequence body
    pure (Foreach nt name e' bodyT)


inferExp :: Expr Parsed -> Infer (AType, Expr Typed)
inferExp = cata \case
  IF x -> pure (TInt, I x)
  BF x -> pure (TBool, B x)
  BottomF -> pure (TNull, Bottom)
  IdF _ i -> findInEnv i >>= \case
    Nothing -> error $ "Couldn't find id " <> i
    Just t -> pure (t, Id t i) 
  InF e1 e2 -> do
    (t1, e1') <- e1
    (t2, e2') <- e2
    constraint t2 (TSet t1)
    pure (TBool, In e1' e2')
    -- TODO: Map
  NotInF e1 e2 -> do
    (t1, e1') <- e1
    (t2, e2') <- e2
    constraint t2 (TSet t1)
    pure (TBool, NotIn e1' e2')
    -- TODO: Map
  EqF e1 e2 -> do
    (t1, e1') <- e1
    (t2, e2') <- e2
    constraint t1 t2
    pure (TBool, Eq e1' e2')
  NotEqF e1 e2 -> do
    (t1, e1') <- e1
    (t2, e2') <- e2
    constraint t1 t2
    pure (TBool, NotEq e1' e2')
  SetF _ s -> do
    s' <- sequence s
    case s' of
      [] -> do
        newTV <- TVar <$> fresh
        pure (TSet newTV, Set newTV [])
      (t, x):xs -> do
        xs' <- forM xs \(t', x') -> do
                constraint t' t
                pure x'
        pure (TSet t, Set t (x:xs'))
  MapF _ m -> error "infer map"
  UnionF _ e1 e2 -> do
    -- TODO: Only works for sets yet, but should also work for maps.
    (t1, e1') <- e1
    (t2, e2') <- e2
    constraint t1 t2
    -- TODO: Constraint to set or map
    pure (t1, Union t1 e1' e2')
  DifferenceF _ e1 e2 -> do
    -- TODO: Only works for sets yet, but should also work for maps.
    (t1, e1') <- e1
    (t2, e2') <- e2
    constraint t1 t2
    -- TODO: Constraint to set or map
    pure (t1, Difference t1 e1' e2')

isPrimT :: AType -> Bool
isPrimT = \case
  TInt  -> True
  TBool -> True
  _     -> False
  

runInfer :: Infer a -> (a, [Constraint])
runInfer m = evalRWS m mempty (Uniq 0)

solve :: [Constraint] -> Either TypeError Subst
solve constraints = fst <$> runIdentity (runExceptT (runStateT solver (mempty, constraints)))

type Solver = StateT Unifier (ExceptT TypeError Identity)
type Subst = M.Map Int AType
type Unifier = (Subst, [Constraint])
data TypeError
  = UnificationFail AType AType
  | UnificationMismatch [AType] [AType]
  | InfiniteType Int AType
  | PrimTypesCantBeNull AType
  deriving Show

solver :: Solver Subst
solver = do
  (su, cs) <- get
  case cs of
    [] -> return su
    ((t1, t2): cs0) -> do
      su1 <- unifies t1 t2
      put (su1 `compose` su, applySubst su1 cs0)
      solver

unifies :: AType -> AType -> Solver Subst
unifies a b = case (a, b) of
  (TNull, t)
    | isPrimT t -> throwError $ PrimTypesCantBeNull t
    | otherwise -> pure mempty
  (t, TNull)
    | isPrimT t -> throwError $ PrimTypesCantBeNull t
    | otherwise -> pure mempty
  (TVar v, t) -> v `bind` t
  (t, TVar v) -> v `bind` t
  (TSet t1, TSet t2) -> unifies t1 t2
  (TMap t1, TMap t2) -> unifies t1 t2
  (TVoidFun ts1, TVoidFun ts2) -> unifyMany ts1 ts2
  (t1, t2) -> if t1 == t2 then pure mempty else throwError $ UnificationFail t1 t2

unifyMany :: [AType] -> [AType] -> Solver Subst
unifyMany [] [] = pure mempty
unifyMany (t1 : ts1) (t2 : ts2) =
  do su1 <- unifies t1 t2
     su2 <- unifyMany (applySubst su1 ts1) (applySubst su1 ts2)
     pure (su2 `compose` su1)
unifyMany t1 t2 = throwError $ UnificationMismatch t1 t2

bind :: Int -> AType -> Solver Subst
bind a t | t == TVar a     = pure mempty
         | occursCheck a t = throwError $ InfiniteType a t
         | otherwise       = return $ M.singleton a t
  where
    occursCheck ::  Substitutable a => Int -> a -> Bool
    occursCheck a' t' = a' `S.member` ftv t'

compose :: Subst -> Subst -> Subst
s1 `compose` s2 = M.map (applySubst s1) s2 `M.union` s1

class Substitutable a where
  applySubst :: Subst -> a -> a
  ftv :: a -> S.Set Int

instance Substitutable AType where
  applySubst s = cata \case
    TIntF -> TInt
    TBoolF -> TBool
    TStringF -> TString
    TSetF t -> TSet t
    TMapF t -> TMap t
    TVoidFunF ts -> TVoidFun ts
    TClassF n -> TClass n
    TVarF i -> M.findWithDefault (TVar i) i s
    TNullF -> TNull

  ftv = cata \case
    TIntF -> mempty
    TBoolF -> mempty
    TStringF -> mempty
    TSetF t -> t
    TMapF t -> t
    TVoidFunF ts -> mconcat ts
    TClassF _ -> mempty
    TVarF i -> S.singleton i
    TNullF -> mempty

instance Substitutable a => Substitutable [a] where
  applySubst = map . applySubst
  ftv as = mconcat $ map ftv as

instance (Substitutable a, Substitutable b) => Substitutable (a, b) where
  applySubst s (a, b) = (applySubst s a, applySubst s b)
  ftv (a, b) = ftv a <> ftv b

instance Substitutable (Algorithm Typed) where
  applySubst s (P i st tops) = P (applySubst s i) (applySubst s st) (applySubst s tops)
  ftv (P i st tops) = ftv i <> ftv st <> ftv tops

instance Substitutable (InterfaceD Typed) where
  applySubst s (InterfaceD tv reqs inds) = InterfaceD (applySubst s tv) reqs inds
  ftv (InterfaceD tv _ _) = ftv tv
    
instance Substitutable (StateD Typed) where
  applySubst s (StateD tvs vs) = StateD (applySubst s tvs) vs
  ftv (StateD tvs _) = ftv tvs

instance Substitutable (TopDecl Typed) where
  applySubst s = \case
    UponD tvs fld body -> UponD (applySubst s tvs) fld (applySubst s body)
    UponReceiveD tvs i as body -> UponReceiveD (applySubst s tvs) i as (applySubst s body)
  ftv = \case
    UponD tvs _ body -> ftv tvs <> ftv body
    UponReceiveD tvs _ _ body -> ftv tvs <> ftv body

instance Substitutable (Statement Typed) where
  applySubst s = cata \case
    AssignF i e -> Assign i (applySubst s e)
    IfF e thenS elseS -> If (applySubst s e) thenS elseS
    TriggerSendF i e -> TriggerSend i (applySubst s e)
    TriggerF (FLCall i e) -> Trigger $ FLCall i (applySubst s e)
    ForeachF tv i e stmts -> Foreach (applySubst s tv) i (applySubst s e) stmts
  ftv = cata \case
    AssignF _ _ -> mempty
    IfF _ thenS elseS -> mconcat (thenS <> elseS)
    TriggerF (FLCall _ e) -> ftv e
    TriggerSendF _ e -> ftv e
    ForeachF tv _ _ stmts -> ftv tv <> mconcat stmts

instance Substitutable (Expr Typed) where
  applySubst s = cata \case
    SetF t n -> Set (applySubst s t) n
    MapF t n -> Map (applySubst s t) n
    UnionF t e f -> Union (applySubst s t) e f
    DifferenceF t e f -> Difference (applySubst s t) e f
    InF e f -> In e f
    NotInF e f -> NotIn e f
    EqF e f -> Eq e f
    NotEqF e f -> NotEq e f
    IF x -> I x
    BF x -> B x
    IdF t x -> Id (applySubst s t) x
    BottomF -> Bottom

  ftv = cata \case
    SetF t e -> ftv t <> mconcat e
    MapF t e -> error "Map"
    UnionF t e f -> ftv t <> e <> f
    DifferenceF t e f -> ftv t <> e <> f
    InF e f -> e <> f
    NotInF e f -> e <> f
    EqF e f -> e <> f
    NotEqF e f -> e <> f
    _ -> mempty

-- Util

fresh :: Infer Int
fresh = do
  Uniq i <- get
  modify' (Uniq . (+1) . coerce)
  pure i

constraint :: AType -> AType -> Infer ()
constraint a b = tell [(a,b)]

pushScope :: [(Identifier, AType)] -> Infer a -> Infer a
pushScope (M.fromList -> l) = local (l:)

findInEnv :: Identifier -> Infer (Maybe AType)
findInEnv i' = do
  findInEnv' i' <$> ask
    where
      findInEnv' :: Identifier -> REnv -> Maybe AType
      findInEnv' i = \case
        [] -> Nothing
        x:xs -> case M.lookup i x of
                  Nothing -> findInEnv' i xs
                  Just t  -> Just t
