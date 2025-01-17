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
        \(FLDecl r args) -> (r,) . (`TFun` TVoid) <$> mapM (\(Arg _ t) -> do
            v <- TVar <$> fresh
            case t of
              Nothing -> pure v
              Just t' -> constraint t' v >> pure v) args

      indVars <- forM indications $
        \(FLDecl i args) -> (i,) . (`TFun` TVoid) <$> mapM (\(Arg _ t) -> do
            v <- TVar <$> fresh
            case t of
              Nothing -> pure v
              Just t' -> constraint t' v >> pure v) args

      pushScope (reqVars <> indVars) $ mapM inferAlg ps

expType :: Expr Typed -> AType
expType = cata \case
  NotEF _ -> TBool
  MapAccessF t2 _ _ -> t2
  TupleF t1 t2 -> TTuple t1 t2
  BottomF -> TNull
  CallF t _ -> t
  IF _ -> TInt
  BF _ -> TBool
  IdF t _ -> t
  BOpF bop t1 _ ->
    case bop of
      Syntax.ADD -> TInt 
      Syntax.MINUS -> TInt 
      Syntax.MUL -> TInt 
      Syntax.DIV -> TInt 
      -- TODO: next 2 Only works for sets yet, but should also work for maps.
      Syntax.DIFFERENCE -> t1
      Syntax.UNION -> t1
      _       -> TBool
  SetOrMapF t _ -> t
  SizeOfF _ -> TInt
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
        UponReceiveD _ n _ _ -> n
        UponTimerD _ (FLDecl n _) _ -> n
        ProcedureD _ (FLDecl n _) _ -> n

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
      stmtsT <- pushScope (zipWith (\(Arg n _) t -> (n,t)) args argsTypes) $ inferStmts stmts
      findInEnv name >>= \case
        Nothing -> error $ "Not in scope" <> name
        Just funT -> constraint funT (TFun argsTypes TVoid)
      pure (UponReceiveD argsTypes name args stmtsT)

  UponD _ (FLDecl name args) stmts -> do
      newScope <- mapM (\(Arg n t) -> (n,) <$> maybe (TVar <$> fresh) pure t) args
      let argsTypes = map snd newScope
      stmtsT <- pushScope newScope $ inferStmts stmts
      findInEnv name >>= \case
        Nothing -> error $ "Not in scope" <> name
        Just funT -> constraint funT (TFun argsTypes TVoid)
      pure (UponD argsTypes (FLDecl name args) stmtsT)

  ProcedureD _ (FLDecl name args) stmts -> do
      newScope <- mapM (\(Arg n t) -> (n,) <$> maybe (TVar <$> fresh) pure t) args
      retTV <- TVar <$> fresh
      let argsTypes = map snd newScope
      stmtsT <- pushScope newScope $ inferStmts stmts
      findInEnv name >>= \case
        Nothing -> error $ "Procedure not in scope" <> name
        Just funT -> constraint funT (TFun argsTypes retTV)
      pure (ProcedureD argsTypes (FLDecl name args) stmtsT)

  UponTimerD _ (FLDecl name args) stmts -> do
      newScope <- mapM (\(Arg n t) -> (n,) <$> maybe (TVar <$> fresh) pure t) args
      let argsTypes = map snd newScope
      stmtsT <- pushScope newScope $ inferStmts stmts
      findInEnv name >>= \case
        Nothing -> error $ "Timer not in scope" <> name
        Just funT -> constraint funT (TFun argsTypes TVoid)
      pure (UponTimerD argsTypes (FLDecl name args) stmtsT)


inferStmts :: [Statement Parsed] -> Infer [Statement Typed]
inferStmts [] = pure []
inferStmts (stmt:stmts) = do
  (stmtT, mit) <- inferStmt stmt
  case mit of
    Nothing -> (stmtT:) <$> inferStmts stmts
    Just v -> (stmtT:) <$> pushScope [v] (inferStmts stmts)
  where
  inferStmt :: Statement Parsed -> Infer (Statement Typed, Maybe (Identifier, AType))
  inferStmt = \case
    Assign _ lhs e -> do
      (t, e') <- inferExp e
      case lhs of
        IdA i -> do
          findInEnv i >>= \case
            Nothing ->
              -- we don't find this variable in scope, so we create it, and return it: this value will be used to push a scope on the next statements
              pure (Assign (Just t) (IdA i) e', Just (i, t))
            Just it -> constraint it t >> pure (Assign Nothing (IdA i) e', Nothing)
        MapA i ix -> do
          (tix, ix') <- inferExp ix
          findInEnv i >>= \case
            -- we don't find this variable in scope, but the map should already exist
            Nothing -> error $ "var not in scope " <> show i
            Just it -> do
              constraint it (TMap tix t)
              pure (Assign Nothing (MapA i ix') e', Nothing)

    If e thenS elseS -> do
      (t, e') <- inferExp e
      constraint t TBool
      thenS' <- inferStmts thenS
      elseS' <- inferStmts elseS
      pure (If e' thenS' elseS', Nothing)
   
    TriggerSend name args -> do

        (argTys, args') <- unzip <$> mapM inferExp args
        findInEnv name >>= \case
          Nothing   -> error $ "Couldn't find " <> name <> " in Send Trigger"
          Just funT -> constraint funT (TFun argTys TVoid)
        pure (TriggerSend name args', Nothing)

    Trigger flCall -> (,Nothing) . Trigger <$> inferFLCall TVoid flCall
    CancelTimer flCall -> (,Nothing) . CancelTimer <$> inferFLCall TVoid flCall

    SetupTimer name timer args -> do
      (timerTy, timer') <- inferExp timer
      (argTys, args') <- unzip <$> mapM inferExp args
      constraint timerTy TInt -- timer first param == int
      findInEnv name >>= \case
        Nothing -> pure ()
        Just funT -> constraint funT (TFun argTys TVoid)
      pure (SetupPeriodicTimer name timer' args', Nothing)

    SetupPeriodicTimer name timer args -> do
      (timerTy, timer') <- inferExp timer
      (argTys, args') <- unzip <$> mapM inferExp args
      constraint timerTy TInt -- timer first param == int
      findInEnv name >>= \case
        Nothing -> pure ()
        Just funT -> constraint funT (TFun argTys TVoid)
      pure (SetupPeriodicTimer name timer' args', Nothing)

    Foreach _ pat e body -> do
      (t, e') <- inferExp e
      (ft, bodyT) <- case pat of
        IdP name -> do
          nt <- TVar <$> fresh
          constraint t (TSet nt)
          (nt,) <$> pushScope [(name, nt)] (inferStmts body)
        TupleP name1 name2 -> do
          nt1 <- TVar <$> fresh
          nt2 <- TVar <$> fresh
          constraint t (TMap nt1 nt2)
          (TTuple nt1 nt2,) <$> pushScope [(name1, nt1), (name2, nt2)] (inferStmts body)
      pure (Foreach ft pat e' bodyT, Nothing)

    While e body -> do
      (_, e') <- inferExp e
      bodyT   <- inferStmts body
      pure (While e' bodyT, Nothing)

    ExprStatement e -> (,Nothing) . ExprStatement . snd <$> inferExp e
    ReturnE e -> do
      -- TODO: Constraint to return type of most recent upon block
      (,Nothing) . ReturnE . snd <$> inferExp e

inferFLCall :: AType -> FLCall Parsed -> Infer (FLCall Typed)
inferFLCall retType (FLCall name args) = do
  (argTys, args') <- unzip <$> mapM inferExp args
  findInEnv name >>= \case
    Nothing -> pure () -- If name isn't found it is a notification and don't add any extra constraint
    Just funT -> constraint funT (TFun argTys retType)
  pure (FLCall name args')


inferExp :: Expr Parsed -> Infer (AType, Expr Typed)
inferExp = cata \case
  NotEF e -> do
    (t, e') <- e
    constraint t TBool
    pure (TBool, NotE e')
  MapAccessF _ i e -> do
    (t, e') <- e
    findInEnv i >>= \case
        Nothing -> error $ "Couldn't find id " <> i
        Just ft -> do
          vt <- TVar <$> fresh
          constraint ft (TMap t vt)
          pure (vt, MapAccess vt i e')
  TupleF e1 e2 -> do
    (t1, e1') <- e1
    (t2, e2') <- e2
    pure (TTuple t1 t2, Tuple e1' e2')
  CallF _ flCall -> do
    n <- TVar <$> fresh
    (n,) . Call n <$> inferFLCall n flCall
  IF x -> pure (TInt, I x)
  BF x -> pure (TBool, B x)
  BottomF -> pure (TNull, Bottom)
  IdF _ i -> findInEnv i >>= \case
    Nothing -> error $ "Couldn't find id " <> i
    Just t -> pure (t, Id t i) 
  BOpF bop e1 e2 -> do
    (t1, e1') <- e1
    (t2, e2') <- e2
    case bop of
      Syntax.SUBSETEQ -> do
        -- TODO: Or TMap ??
        t3 <- TSet . TVar <$> fresh
        constraint t1 t2 <* constraint t1 t3
      Syntax.ADD -> constraint t1 TInt <* constraint t2 TInt
      Syntax.MINUS -> constraint t1 TInt <* constraint t2 TInt
      Syntax.MUL -> constraint t1 TInt <* constraint t2 TInt
      Syntax.DIV -> constraint t1 TInt <* constraint t2 TInt
      Syntax.EQ -> constraint t1 t2
      Syntax.NE -> constraint t1 t2
      Syntax.LE -> constraint t1 TInt <* constraint t2 TInt
      Syntax.GE -> constraint t1 TInt <* constraint t2 TInt
      Syntax.LT -> constraint t1 TInt <* constraint t2 TInt
      Syntax.GT -> constraint t1 TInt <* constraint t2 TInt
      Syntax.AND -> constraint t1 TBool <* constraint t2 TBool
      Syntax.OR  -> constraint t1 TBool <* constraint t2 TBool
      -- TODO: Map
      Syntax.IN  -> constraint t2 (TSet t1)
      Syntax.NOTIN -> constraint t2 (TSet t1)
      -- TODO: Only works for sets yet, but should also work for maps.
      -- TODO: Constraint set or map
      Syntax.UNION -> constraint t1 t2
      Syntax.DIFFERENCE -> constraint t1 t2
    pure (expType (BOp bop e1' e2'), BOp bop e1' e2')
  SetOrMapF _ s -> do
    s' <- sequence s
    case s' of
      [] -> do
        newTV <- TVar <$> fresh
        pure (newTV, SetOrMap newTV [])
      (t, x):xs -> do
        xs' <- forM xs \(t', x') -> do
                constraint t' t
                pure x'
        let setOrMap = case t of
                         TTuple t1 t2 -> TMap t1 t2
                         t' -> TSet t'
        pure (setOrMap, SetOrMap setOrMap (x:xs'))
  SizeOfF e -> do
    (t, e') <- e
    n <- TVar <$> fresh
    -- TODO: Constraint to set or map
    constraint t (TSet n)
    pure (TInt, SizeOf e')

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
  (TMap t1 t3, TMap t2 t4) -> unifies t1 t2 *> unifies t3 t4
  (TFun ts1 x, TFun ts2 y) -> unifies x y *> unifyMany ts1 ts2
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
    TTupleF t1 t2 -> TTuple t1 t2
    TVoidF -> TVoid
    TIntF -> TInt
    TByteF -> TByte
    TBoolF -> TBool
    TStringF -> TString
    TSetF t -> TSet t
    TMapF t1 t2 -> TMap t1 t2
    TFunF ts x -> TFun ts x
    TClassF n -> TClass n
    TVarF i -> M.findWithDefault (TVar i) i s
    TNullF -> TNull
    TArrayF x -> TArray x

  ftv = cata \case
    TTupleF t1 t2 -> t1 <> t2
    TIntF -> mempty
    TVoidF -> mempty
    TBoolF -> mempty
    TStringF -> mempty
    TByteF -> mempty
    TArrayF t -> t
    TSetF t -> t
    TMapF t1 t2 -> t1 <> t2
    TFunF ts x -> mconcat ts <> x
    TClassF _ -> mempty
    TVarF i -> S.singleton i
    TNullF -> mempty

instance Substitutable a => Substitutable (Maybe a) where
  applySubst = fmap . applySubst
  ftv = maybe mempty ftv

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
    ProcedureD tvs fld body -> ProcedureD (applySubst s tvs) fld (applySubst s body)
    UponTimerD tvs fld body -> UponTimerD (applySubst s tvs) fld (applySubst s body)
  ftv = \case
    UponD tvs _ body -> ftv tvs <> ftv body
    UponReceiveD tvs _ _ body -> ftv tvs <> ftv body
    ProcedureD tvs _ body -> ftv tvs <> ftv body
    UponTimerD tvs _ body -> ftv tvs <> ftv body

instance Substitutable (Statement Typed) where
  applySubst s = cata \case
    CancelTimerF flc -> CancelTimer (applySubst s flc)
    AssignF t i e -> Assign (applySubst s t) (applySubst s i) (applySubst s e)
    IfF e thenS elseS -> If (applySubst s e) thenS elseS
    TriggerSendF i e -> TriggerSend i (applySubst s e)
    TriggerF flc -> Trigger $ applySubst s flc
    SetupPeriodicTimerF n t args -> SetupPeriodicTimer n (applySubst s t) (applySubst s args)
    SetupTimerF n t args -> SetupPeriodicTimer n (applySubst s t) (applySubst s args)
    ForeachF tv i e stmts -> Foreach (applySubst s tv) i (applySubst s e) stmts
    WhileF e stmts -> While (applySubst s e) stmts
    ExprStatementF x -> ExprStatement (applySubst s x)
    ReturnEF e -> ReturnE (applySubst s e)
  ftv = cata \case
    CancelTimerF flc -> ftv flc
    AssignF t _ _ -> ftv t
    IfF _ thenS elseS -> mconcat (thenS <> elseS)
    TriggerF fl -> ftv fl
    SetupPeriodicTimerF _ t args -> ftv t <> ftv args
    SetupTimerF _ t args -> ftv t <> ftv args
    TriggerSendF _ e -> ftv e
    ForeachF tv _ e stmts -> ftv tv <> ftv e <> mconcat stmts
    WhileF e stmts -> ftv e <> mconcat stmts
    ExprStatementF x -> ftv x
    ReturnEF e -> ftv e

instance Substitutable (ALhs Typed) where
  applySubst s = \case
    IdA i -> IdA i
    MapA i e -> MapA i (applySubst s e)
  ftv = \case
    IdA _ -> mempty
    MapA _ e -> ftv e

instance Substitutable (FLCall Typed) where
  applySubst s (FLCall name args) = FLCall name $ applySubst s args
  ftv (FLCall _ args) = ftv args

instance Substitutable (Expr Typed) where
  applySubst s = cata \case
    NotEF e -> NotE e
    MapAccessF t2 e f -> MapAccess (applySubst s t2) e f
    TupleF e f -> Tuple e f
    CallF t flc -> Call (applySubst s t) $ applySubst s flc
    SetOrMapF t n -> SetOrMap (applySubst s t) n
    BOpF bop e f -> BOp bop e f
    IF x -> I x
    BF x -> B x
    IdF t x -> Id (applySubst s t) x
    BottomF -> Bottom
    SizeOfF x -> SizeOf x

  ftv = cata \case
    MapAccessF t2 _ _ -> ftv t2
    CallF t fl    -> ftv t <> ftv fl
    SetOrMapF t e -> ftv t <> mconcat e
    NotEF e -> e
    BOpF _ e f -> e <> f
    SizeOfF x -> x
    TupleF e f -> e <> f
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
