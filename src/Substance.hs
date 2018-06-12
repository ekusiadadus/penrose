-- | "Substance" contains the grammar, parser, and semantic checker for
--   the Substance language. It also contains translators to Alloy and
--   the driver for it.

{-# OPTIONS_HADDOCK prune #-}
module Substance where
--module Main (main) where -- for debugging purposes
-- TODO split this up + do selective export

import Utils
import System.Process
import Data.Void
import Control.Monad (void)
import System.IO -- read/write to file
import System.Environment
import Control.Arrow ((>>>))
import System.Random
import Debug.Trace
import Data.List
import Data.Maybe
import Data.Typeable
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Expr
import Env
-- import Text.PrettyPrint
--import Text.PrettyPrint.HughesPJClass hiding (colon, comma, parens, braces)
import qualified Dsll as D
import qualified Data.Map.Strict as M
import qualified Text.Megaparsec.Char.Lexer as L

--------------------------------------- Substance AST ---------------------------------------

data ValConstructorName = ValConst String             -- “Cons”, “Times”
                          deriving (Show, Eq, Typeable)

data OperatorName = OperatorConst String             -- “Intersection”
                    deriving (Show, Eq, Typeable)

data PredicateName = PredicateConst String            -- “Intersect”
                     deriving (Show, Eq, Typeable)

data Func = Func { nameFunc :: String,
                   argFunc :: [Expr] }
            deriving (Eq, Typeable)

instance Show Func where
    show (Func nameFunc argFunc) = nString ++ "(" ++ aString ++ ")"
        where nString = show nameFunc
              aString = show argFunc

data Expr = VarE Var
          | ApplyExpr Func
          deriving (Show, Eq, Typeable)

data PredArg = PE Expr
             | PP Predicate
             deriving (Show, Eq, Typeable)

data Predicate = Predicate { predicateName :: PredicateName,
                             predicateArgs :: [PredArg],
                             predicatePos :: SourcePos }
                 deriving (Eq, Typeable)

instance Show Predicate where
    show (Predicate predicateName predicateArgs pos) = nString ++ "(" ++ aString ++ ")"
        where nString = show predicateName
              aString = show predicateArgs

data SubStmt = Decl T Var
             | Bind Var Expr
             | ApplyP Predicate
             deriving (Show, Eq, Typeable)

-- | Program is a sequence of statements
type SubProg = [SubStmt]
type SubObjDiv = ([SubDecl], [SubConstr])

------------------------------------
-- | Special data types for passing on to the style parser

-- | Declaration of Substance objects
data SubDecl = SubDeclConst T Var
               deriving (Show, Eq, Typeable)

-- | Declaration of Substance constaints
data SubConstr = SubConstrConst String [PredArg]
                 deriving (Show, Eq, Typeable)

-- | Both declarations and constaints in Substance are regarded as objects,
--   which is possible for Style to select later.
data SubObj = LD SubDecl
            | LC SubConstr
            deriving (Show, Eq, Typeable)

--------------------------------------- Substance Parser --------------------------------------

-- | 'substanceParser' is the top-level parser function. The parser contains a list of functions
--    that parse small parts of the language. When parsing a source program, these functions are invoked in a top-down manner.
substanceParser :: Parser [SubStmt]
substanceParser = between scn eof subProg -- Parse all the statemnts between the spaces to the end of the input file

-- |'subProg' parses the entire actual Substance Core language program which is a collection of statements
subProg :: Parser [SubStmt]
subProg = do
  stml <- subStmt `sepEndBy` newline'
  return stml

predicateNameParser :: Parser PredicateName
predicateNameParser = do
    i <- identifier
    return (PredicateConst i)

functionParser :: Parser Func
functionParser = do
  n <- identifier
  args <- parens (exprParser `sepBy1` comma)
  return (Func { nameFunc = n, argFunc = args })

exprParser, varE, applyF :: Parser Expr
exprParser = try applyF <|> try varE
varE = do
  i <- varParser
  return (VarE i)
applyF = do
  f <- functionParser
  return (ApplyExpr f)

predicateArgParser, predicateArgParserE, predicateArgParserP  :: Parser PredArg
predicateArgParser = try predicateArgParserE <|> predicateArgParserP
predicateArgParserE = do
  e <- exprParser
  return (PE e)
predicateArgParserP = do
  p <- predicateParser
  return (PP p)

predicateParser :: Parser Predicate
predicateParser = do
  n    <- predicateNameParser
  args <- parens (predicateArgParser `sepBy1` comma)
  pos  <- getPosition
  return (Predicate { predicateName = n, predicateArgs = args, predicatePos = pos })

subStmt, decl, bind, applyP :: Parser SubStmt
subStmt = try bind <|> try decl <|> applyP
decl = do
  t' <- tParser
  v' <- varParser
  return (Decl t' v')
bind = do
  v' <- varParser
  eq
  e' <- exprParser
  return (Bind v' e')
applyP = do
  p <- predicateParser
  return (ApplyP p)

----------------------------------------- Substance Typechecker ---------------------------

-- This is the top level function for checking a substance program which calls checkSubStmt on each statement in the
-- program and returnsan updated context from the statement check.
-- Errors are accumulated in the context during checking as they occur.
check :: SubProg -> VarEnv -> VarEnv
check p varEnv = let env = foldl checkSubStmt varEnv p
                 in if (null (errors env))
                    then env
                    else error ("Substance type checking failed with the following problems: \n" ++ (errors env))


-- Statements are checked differently depending on if they are a variable declaration, variable assignment, or predicate statement.
-- Variable declaration statements call checkT to check that the type in the statement is well-formed.
-- The context is updated with errors and the declared variable.
-- A variable assignment statement calls checkVarE and checkExpression to check both the variable and expression in the statement for well-typedness.
-- These functions return a Maybe type of the variable or expression and a string of errors (which may be empty).
-- The error strings are added to the context and the Maybe types are checked for “non-null”
-- values and then equivalence (extra error added to context if the types are not the same for the variable and expression in the statement).
-- Predicate statements are checked by checkPredicate and return a context updated with errors from that checking (if they occur).
checkSubStmt :: VarEnv -> SubStmt -> VarEnv
checkSubStmt varEnv  (Decl t (VarConst n)) = let env  = checkT varEnv t
                                                 env1 = addDeclaredName n env
                                             in env1 { varMap = M.insert (VarConst n) t $ varMap env1 }

checkSubStmt varEnv  (Bind v e) = let (vstr, vt) = checkVarE varEnv v
                                      (estr, et) = checkExpression varEnv e -- TODO: Check lazy evaluation on et
                                  in if (isJust vt && isJust et && vt /= et)
                                     then varEnv { errors = (errors varEnv) ++ vstr ++ estr ++ "Expression of type "
                                                   ++ (show et)
                                                   ++ " assigned to variable of type " ++ (show vt) ++ "\n"}
                                     else varEnv { errors = (errors varEnv) ++ vstr ++ estr }

checkSubStmt varEnv  (ApplyP p) = checkPredicate varEnv p

-- The predicate is looked up in the context; if the context doesn’t contain the predicate, then an error is added to the
-- context, otherwise it is checked differently depending on if it takes expressions or other predicates as arguments by
-- calling checkVarPred or checkRecursePred respectively. Any errors found within those checking functions will be accumulated
-- in the context returned by those functions and ultimately this function.
checkPredicate :: VarEnv -> Predicate -> VarEnv
checkPredicate varEnv (Predicate (PredicateConst p) args pos) =
               case checkAndGet p (predicates varEnv) pos of
               Right p -> case p of
                 Pred1 p1 -> checkVarPred varEnv args p1
                 Pred2 p2 -> checkRecursePred varEnv args
               Left _ -> case checkAndGet p (operators varEnv) pos of
                 Right o -> checkVarOperator varEnv args o
                 Left err -> varEnv { errors = (errors varEnv) ++ err }


areAllArgTypes argTypes = (foldl (\b at1 -> b && isJust at1) True argTypes)


-- First, this function ensures all the supplied predicate arguments are in fact expressions using isVarPredicate.
-- If they are not, then an execution stopping error is thrown (the error is not in the checking of the program)
-- These expressions are checked by checkExpression for well-typedness returning a list of error strings and Maybe types.
-- The Maybe types list is checked for all “non-null” types.
-- If even one type is “null”, then there were checking failures and the error string is added to the context.
-- Otherwise, the error string is empty and type substitution “sigma” is generated from calling the substitution
-- function on the predicate argument types and formal types stored in the context.
-- The substitution need not be applied to any types for predicates, because using the argument types to create the
-- substitution ensures the argument types match the substitution applied to each formal type.
checkVarPred :: VarEnv -> [PredArg] -> Predicate1 -> VarEnv
checkVarPred varEnv args (Prd1 name yls kls tls _) =
             let exprArgs      = map isVarPredicate args
                 errAndTypesLs = map (checkExpression varEnv) exprArgs
                 errls         = firsts errAndTypesLs
                 err           = foldl (\err1 err2 -> err1 ++ err2) "" errls
                 argTypes      = seconds errAndTypesLs
             in if areAllArgTypes argTypes
                then let argTypes2 = map (\a -> KT (fromJust a)) argTypes
                         tls2      = map (\a -> KT a) tls
                         sigma     = subst varEnv M.empty argTypes2 tls2
                     in varEnv { errors = (errors varEnv) ++ err } -- err should be empty str
                else
                 varEnv { errors = (errors varEnv) ++ err}

checkVarOperator :: VarEnv -> [PredArg] -> Env.Operator -> VarEnv
checkVarOperator varEnv args (Operator name yls kls tls _) =
                  let exprArgs      = map isVarPredicate args
                      errAndTypesLs = map (checkExpression varEnv) exprArgs
                      errls         = firsts errAndTypesLs
                      err           = foldl (\err1 err2 -> err1 ++ err2) "" errls
                      argTypes      = seconds errAndTypesLs
                  in if areAllArgTypes argTypes
                     then let argTypes2 = map (\a -> KT (fromJust a)) argTypes
                              tls2      = map (\a -> KT a) tls
                              sigma     = subst varEnv M.empty argTypes2 tls2
                          in if (sigma == M.empty)
                             then varEnv { errors = (errors varEnv) ++ err } -- err should be empty str
                             else varEnv { errors = (errors varEnv) ++ err } -- err should be empty str
                     else
                      varEnv { errors = (errors varEnv) ++ err}

-- Helper function to determine if predicate arguments are all expressions.
-- It will stop execution if a supplied predicate argument to the function is not an expression.
isVarPredicate :: PredArg -> Expr
isVarPredicate (PP p) = error "Mixed predicate types!"
isVarPredicate (PE p) = p

-- Helper function to determine if predicate arguments are all predicates. 
-- It will stop execution if a supplied predicate argument to the function is not a predicate.
isRecursedPredicate :: PredArg -> Predicate
isRecursedPredicate (PP p) = p
isRecursedPredicate (PE p) = error "Mixed predicate types!"

-- This function, first, ensures all the supplied predicate arguments are predicates.
-- It calls checkPredicate (recursively) on each argument predicate returning the context with any accumulated errors found
-- when checking each argument predicate for well-formedness (if there are any).
checkRecursePred :: VarEnv -> [PredArg] -> VarEnv
checkRecursePred varEnv args = let predArgs = map isRecursedPredicate args
                               in foldl checkPredicate varEnv predArgs

-- This function checks expressions for well-typedness and does it differently for variables or functions/value constructors
-- calling checkVarE and checkFunc respectively for each case.]
-- If errors were found during checking then they are accumulated and returned in a tuple with the Maybe type for the expression.
checkExpression :: VarEnv -> Expr -> (String, Maybe T)
checkExpression varEnv (VarE v) = checkVarE varEnv v
checkExpression varEnv (ApplyExpr f) = checkFunc varEnv f


-- Checking a variable expression for well-typedness involves looking it up in the context.
-- If it cannot be found in the context, then a tuple is returned of a non-empty error string warning of this problem and
-- a “null” type. Otherwise, a tuple of an empty string and “non-null” type for the variable from the context is returned.
checkVarE :: VarEnv -> Var -> (String, Maybe T)
checkVarE varEnv v = case M.lookup v (varMap varEnv) of
                     Nothing -> ("Variable " ++ (show v) ++ " not in environment\n", Nothing)
                     vt      -> ("", vt)

--  Looks up the operator or value-constructor in the context. If it cannot be found in the context,
-- then a tuple is returned of a non-empty error string warning of this problem and a “null” type.
-- Otherwise, a tuple of an error string and Maybe type is returned from calls to checkVarConsInEnv and checkFuncInEnv 
-- depending on if the Func supplied to this function is an value constructor or operator. 
checkFunc :: VarEnv -> Func -> (String, Maybe T)
checkFunc varEnv (Func f args) = let vcEnv = M.lookup f (valConstructors varEnv)
                                     fEnv  = M.lookup f (operators varEnv)
                                 in if (isNothing(vcEnv) && isNothing(fEnv))
                                    then ("Function or Val Constructor " ++ (show f) ++ " not in environment\n", Nothing)
                                    else if (isJust(vcEnv))
                                         then checkVarConsInEnv varEnv (Func f args) (fromJust vcEnv)
                                    else checkFuncInEnv varEnv (Func f args) (fromJust fEnv)

-- Operates very similarly to checkVarPred described above.
-- The only differences are that this function operates on operators (so checking of arguments to be expressions is 
-- unnecessary due to operator parsing) and returns a tuple of an error string and Maybe type.
-- If the substitution “sigma” is generate, then if it is empty, a tuple of an empty error string and the formal
-- return type of the operator is returned, otherwise (if it is not empty) a tuple of an empty error string and the
-- substituted formal return type of the operator is returned. If checking failed for any of the arguments of the operator,
-- then “sigma” is not generated and a tuple of a non-empty error string and “null” type is returned.
checkFuncInEnv :: VarEnv -> Func -> Env.Operator -> (String, Maybe T)
checkFuncInEnv varEnv (Func f args) (Operator name yls kls tls t) =
               let errAndTypesLs = map (checkExpression varEnv) args
                   errls         = map (\(err1,t1) -> err1) errAndTypesLs
                   err           = foldl (\err1 err2 -> err1 ++ err2) "" errls
                   argTypes      = map (\(err1,t1) -> t1) errAndTypesLs
               in if (foldl (\b at1 -> b && isJust at1) True argTypes)
                  then let argTypes2 = map (\a -> KT (fromJust a)) argTypes
                           tls2      = map (\a -> KT a) tls
                           sigma     = subst varEnv M.empty argTypes2 tls2
                       in if (sigma == M.empty)
                          then (err, Just t) -- err should be empty str
                          else (err, Just (applySubst sigma t)) -- err should be empty str
                  else (err, Nothing)

-- Operates exactly the same as checkFuncInEnv above it just operates over value constructors instead of operators.
checkVarConsInEnv  :: VarEnv -> Func -> ValConstructor -> (String, Maybe T)
checkVarConsInEnv varEnv (Func f args) (ValConstructor name yls kls tls t) =
                  let errAndTypesLs = map (checkExpression varEnv) args
                      errls         = map (\(err1,t1) -> err1) errAndTypesLs
                      err           = foldl (\err1 err2 -> err1 ++ err2) "" errls
                      argTypes      = map (\(err1,t1) -> t1) errAndTypesLs
                  in if (foldl (\b at1 -> b && isJust at1) True argTypes)
                     then let argTypes2 = map (\a -> KT (fromJust a)) argTypes
                              tls2      = map (\a -> KT a) tls
                              sigma     = subst varEnv M.empty argTypes2 tls2
                           in if (sigma == M.empty)
                              then (err, Just t) -- err should be empty str
                              else (err, Just (applySubst sigma t)) -- err should be empty str
                     else (err, Nothing)

-- Takes a substitution “sigma” and applies it to a type. Types that are single type variables are mapped to their corresponding
-- type which exists in “sigma”. Types that are type constructors are mapped to the same type but with their arguments
-- substituted by “sigma” using applySubstitutionHelper.
applySubst :: M.Map Y Arg -> T -> T
applySubst sigma (TTypeVar vt) = 
           case sigma M.! (TypeVarY vt) of
           AVar v -> error "Type var being mapped to variable in subst sigma, error in the TypeChecker!"
           AT t   -> t
applySubst sigma (TConstr (TypeCtorApp t args pos)) =
           let argsSub = map (applySubstHelper sigma) args
           in TConstr (TypeCtorApp t argsSub pos)

-- This is a helper function which applies a substitution “sigma” to an argument of a type constructor.
-- If the argument is a variable, then it is mapped to its corresponding variable which exists in “sigma”.
-- If the argument is a type, then it is mapped to the “sigma” substitution of itself using a recursive call to applySubstitution
applySubstHelper :: M.Map Y Arg -> Arg -> Arg
applySubstHelper sigma (AVar v) = case sigma M.! (VarY v) of
                                  res@(AVar v2) -> res
                                  AT t -> error "Var being mapped to a type in subst sigma, error in the TypeChecker!"
applySubstHelper sigma (AT t) = AT (applySubst sigma t)

-- This function (along with its helper functions) follows a recursive-descent unification algorithm to find a substitution
-- “sigma” for two type lists. It generates an entry in a substitution map “sigma” whenever a list of argument types (from
-- a Substance program) and its corresponding list of formal types (from the context) differ.
-- All entries in “sigma” must be consistent for it to be a valid substitution.
-- substitutionHelper is called on each element of a list of tuples of corresponding argument and formal types to generate
-- entries in a substitution “sigma”.
subst :: VarEnv -> M.Map Y Arg -> [K] -> [K] -> M.Map Y Arg
subst varEnv sigma argTypes formalTypes = let types = zip argTypes formalTypes
                                              sigma2 = foldl (substHelper varEnv) sigma types
                                          in if ((length argTypes) /= (length formalTypes))
                                            then error ("Arguments list lengths are not equal")
                                            else  sigma2

-- Ensures an argument type and formal type matches where they should match, otherwise a runtime error is generated.
-- In places where they do not need to match exactly (where type and regular variables exist in the formal type)
-- a substitution entry is generated. substitutionHelper2 helps in generating these entries for type constructor arguments and
-- substitutionInsert does the insertion of the entry into the substitution map “sigma”.
substHelper :: VarEnv -> M.Map Y Arg -> (K, K) -> M.Map Y Arg
substHelper varEnv sigma ((Ktype aT), (Ktype fT)) = sigma
substHelper varEnv sigma ((KT (TTypeVar atv)), (KT (TTypeVar ftv))) =
                   substInsert sigma (TypeVarY ftv) (AT (TTypeVar atv))
substHelper varEnv sigma ((KT (TConstr (TypeCtorApp atc argsAT pos))), (KT (TTypeVar ftv))) =
                   substInsert sigma (TypeVarY ftv) (AT (TConstr (TypeCtorApp atc argsAT pos)))
substHelper varEnv sigma ((KT (TConstr (TypeCtorApp atc argsAT pos1))), (KT (TConstr (TypeCtorApp ftc argsFT pos2)))) =
                   if ((atc `elem` (declaredNames varEnv)) || (ftc `elem` (declaredNames varEnv)))
                   then substHelper2 varEnv sigma ((AVar (VarConst atc)), (AVar (VarConst ftc)))
                   else if (atc /= ftc)
                        then error ("Argument type " ++ (show atc) ++ " doesn't match expected type " ++ (show ftc))
                        else let args   = zip argsAT argsFT
                                 sigma2 = foldl (substHelper2 varEnv) sigma args
                              in sigma2
substHelper varEnv sigma ((Ktype aT), (KT fT)) =
                   error ("Argument type " ++ (show aT) ++ " doesn't match expected type " ++ (show fT))
substHelper varEnv sigma ((KT (TTypeVar atv)), (KT (TConstr (TypeCtorApp ftc argsFT pos)))) =
                   error ("Argument type " ++ (show atv) ++ " doesn't match expected type " ++ (show ftc))
substHelper varEnv sigma ((KT aT), (Ktype fT)) =
                   error ("Argument type " ++ (show aT) ++ " doesn't match expected type " ++ (show fT))


-- This helper function makes sure an argument type’s argument matches a formal type’s argument where they should match,
-- otherwise a runtime error is generated. In places where they do not need to match exactly 
-- (where type and regular variables exist in the formal type’s argument), a substitution entry is generated and inserted
-- into the substitution map “sigma” using substitutionInsert. Note that substitutionHelper is called recursively to handle
-- substitutions for an argument type’s argument and corresponding formal type’s argument that are both types themselves.
substHelper2 :: VarEnv -> M.Map Y Arg -> (Arg, Arg) -> M.Map Y Arg
substHelper2 varEnv sigma ((AVar av), (AVar fv)) =
                    substInsert sigma (VarY fv) (AVar av)
substHelper2 varEnv sigma ((AT at), (AT ft)) =
                    substHelper varEnv sigma ((KT at), (KT ft))
substHelper2 varEnv sigma ((AVar av), (AT ft)) =
                    error ("Argument type's argument " ++ (show av) ++ " doesn't match expected type's argument " ++ (show ft))
substHelper2 varEnv sigma ((AT at), (AVar fv)) =
                    error("Argument type's argument " ++ (show at) ++ " doesn't match expected type's argument " ++ (show fv))

-- Handles the consistency of entries in the substitution “sigma”, by ensuring that if an entry being inserted into “sigma”
-- already exists in “sigma” it is the same entry as the one already in “sigma”.
-- If the entry doesn’t already exist in “sigma”, then it can be inserted directly without a check for consistency.
substInsert :: M.Map Y Arg -> Y -> Arg -> M.Map Y Arg
substInsert sigma y arg = case M.lookup y sigma of
                          Nothing -> M.insert y arg $ sigma
                          arg'  -> if arg /= (fromJust arg')
                                   then error "Substitutions inconsistent - no subst can exist"
                                   else sigma

--argTypeLookupHelper :: VarEnv -> Y -> Either K String
--argTypeLookupHelper varEnv (TypeVarY t) = case M.lookup t (typeVarMap varEnv) of
--                                   Nothing -> Right "Argument " ++ (show t) ++ " not in environment\n"
--                                   tType -> Left tType
--argTypeLookupHelper varEnv (VarY v) = case M.lookup v (varMap varEnv) of
--                               Nothing -> Right "Argument " ++ (show v) ++ " not in environment\n"
--                               vType -> Left vType


-- --------------------------------------- Substance Loader --------------------------------
-- | Load all the Substance objects for visualization at Runtime.hs

data SubObjects = SubObjects { subObjs :: [SubObj] }
                  -- declared Substance objects (including constraints, which is, again, viewed also as objects)
                  deriving (Show, Eq, Typeable)

applyDef :: Ord k => (k, v) -> M.Map k (a, b) -> b
applyDef (n, _) d = case M.lookup n d of
    Nothing -> error "applyDef: definition not found!"
    Just (_, e) -> e

-- | 'passDecls' checks the validity of declarations of objects.
passDecls :: VarEnv -> SubObjects -> SubStmt -> SubObjects
passDecls subEnv e (Decl t s)  = e { subObjs = toObj subEnv t s : subObjs e }
passDecls subEnv e _ = e -- Ignore all other statements

-- | 'toObj' translates [Type] + [Identiers] to concrete Substance objects, to be selected by the Style program
toObj :: VarEnv -> T -> Var -> SubObj
toObj e t v = LD $ (SubDeclConst (fixAST e t) v)

fixAST :: VarEnv -> T -> T
fixAST e (TConstr c) = TConstr (c { argCons = (map (fixArg e) (argCons c)) })
fixAST e t = t -- Ignore all other cases

fixArg :: VarEnv -> Arg -> Arg
fixArg e (AT (TConstr i)) = if (nameCons i) `elem` (declaredNames e)
                            then AVar (VarConst (nameCons i))
                            else AT (TConstr i)
fixArg e a = a -- Ignore all other cases

-- | 'checkReferencess' checks any statement that refers to other objects. For example,
-- | > Subset A B
-- | refers to identifiers @A@ and @B@. The function will perform a lookup in the symbol table, make sure the objects exist and are of desired types -- in this case, 'Set' -- and throws an error otherwise.
passReferencess :: SubObjects -> SubStmt -> SubObjects
passReferencess e (ApplyP (Predicate (PredicateConst t) args pos)) = e { subObjs = (toConstr t args) : subObjs e }
passReferencess e _ = e -- Ignore all other statements

-- | Similar to 'toObj'
toConstr :: String -> [PredArg] -> SubObj
toConstr p vl = LC $ SubConstrConst p vl

-- | `subSeparate` splits a list of Substance objects into declared objects and constaints on these objects
subSeparate :: [SubObj] -> SubObjDiv
subSeparate = foldr separate ([], [])
              where separate line (decls, constrs) =
                             case line of
                             (LD x) -> (x : decls, constrs)
                             (LC x) -> (decls, x : constrs)

loadObjects :: SubProg -> VarEnv -> SubObjects
loadObjects p objs = let objs1 = foldl (passDecls objs) initObjs p
                         objs2 = foldl passReferencess objs1 p
                     in  objs2 { subObjs = reverse $ subObjs objs2 }
                     where initObjs = SubObjects { subObjs = [] }

-- | 'parseSubstance' runs the actual parser function: 'substanceParser', taking in a program String, parses it, semantically checks it, and eventually invoke Alloy if needed. It outputs a collection of Substance objects at the end.
parseSubstance :: String -> String -> VarEnv -> IO ([SubObj], VarEnv)
parseSubstance subFile subIn varEnv =
               case runParser substanceParser subFile subIn of
               Left err -> error (parseErrorPretty err)
               Right xs -> do
                   putStrLn ("Substance AST: \n")
                   putStrLn (show xs)
                   -- mapM_ print xs
                   divLine
                   let subEnv = check xs varEnv
                       c      = loadObjects xs subEnv
                   return (subObjs c, subEnv)

--------------------------------------------------------------------------------
-- COMBAK: organize this section and maybe rewrite some of the functions

-- | Generate a unique id for a Substance constraint
-- FIXME: make sure these names are unique and make sure users cannot start ids
-- with underscores

varListToString :: [Var] -> [String]
varListToString = map conv
    where conv (VarConst s)  = s

--TODO: Support all the other cases
convPredArg :: PredArg -> String
convPredArg (PE (VarE (VarConst s)))  = s
convPredArg c  = (show c)

predArgListToString :: [PredArg] -> [String]
predArgListToString = map convPredArg

varArgsToString :: [Arg] -> [String]
varArgsToString = map conv
    where conv c = case c of
                       AVar (VarConst s) -> s
                       _ -> ""

exprToString :: [Expr] -> [String]
exprToString = map conv
    where conv c = (show c)


-- TODO: factor out internal naming convention logic
getConstrTuples :: [SubConstr] -> [(TypeName, String, [String])]
getConstrTuples = map getType
    where getType (SubConstrConst p  vs)  = ((TypeNameConst p), "_" ++ p ++ (intercalate "" (predArgListToString vs)), (predArgListToString vs))

getSubTuples :: [SubDecl] -> [(TypeName, String, [String])]
getSubTuples = map getType
    where getType d = case d of
            SubDeclConst (TConstr (TypeCtorApp t xls pos1)) (VarConst v) -> (TypeNameConst t, v, v : varArgsToString xls)
            SubDeclConst (TTypeVar (TypeVar name pos2)) (VarConst v)            -> (TypeNameConst name, v, [v])

getAllIds :: ([SubDecl], [SubConstr]) -> [String]
getAllIds (decls, constrs) = map (\(_, x, _) -> x) $ getSubTuples decls ++ getConstrTuples constrs


-- --------------------------------------- Test Driver -------------------------------------
-- | For testing: first uncomment the module definition to make this module the
-- Main module. Usage: ghc SubstanceCore.hs; ./SubstanceCore <substance core-file>

main :: IO ()
main = do
    args <- getArgs
    let subFile = head args
    subIn <- readFile subFile
    parseTest substanceParser subIn
    --parsed <- parseFromFile
    --mapM_ print parsed
    return ()