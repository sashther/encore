{-# LANGUAGE MultiParamTypeClasses, TypeSynonymInstances, FlexibleInstances, GADTs, NamedFieldPuns #-}

{-| Translate a @ClassDecl@ (see "AST") to its @CCode@ (see
"CCode.Main") equivalent.

 -}

module CodeGen.ClassDecl () where

import CodeGen.Typeclasses
import CodeGen.CCodeNames
import CodeGen.MethodDecl
import CodeGen.ClassTable
import CodeGen.Type
import qualified CodeGen.Context as Ctx

import CCode.Main
import CCode.PrettyCCode

import Data.List

import qualified AST.AST as A
import qualified Identifiers as ID
import qualified Types as Ty

import Control.Monad.Reader hiding (void)

instance Translatable A.ClassDecl (ClassTable -> CCode FIN) where
  translate cdecl ctable
      | A.isActive cdecl = translateActiveClass cdecl ctable
      | otherwise        = translatePassiveClass cdecl ctable

-- | Translates an active class into its C representation. Note
-- that there are additional declarations in the file generated by
-- "CodeGen.Header"
translateActiveClass cdecl@(A.Class{A.cname, A.fields, A.methods}) ctable =
    Program $ Concat $
      (LocalInclude "header.h") :
      [type_struct_decl] ++
      [runtime_type_init_fun_decl cdecl] ++
      [tracefun_decl cdecl] ++
      method_impls ++
      [dispatchfun_decl] ++
      [runtime_type_decl cname]
    where
      type_struct_decl :: CCode Toplevel
      type_struct_decl =
          let typeParams = Ty.getTypeParameters cname in
          StructDecl (AsType $ class_type_name cname) $
                     ((encore_actor_t, Var "_enc__actor") :
                      (map (\ty -> (Ptr pony_type_t, AsLval $ type_var_ref_name ty)) typeParams ++
                         zip
                         (map (translate  . A.ftype) fields)
                         (map (AsLval . field_name . A.fname) fields)))

      method_impls = map method_impl methods
          where
            method_impl mdecl = translate mdecl cdecl ctable

      dispatchfun_decl :: CCode Toplevel
      dispatchfun_decl =
          (Function (Static void) (class_dispatch_name cname)
           ([(Ptr . Typ $ "pony_actor_t", Var "_a"),
             (Ptr . Typ $ "pony_msg_t", Var "_m")])
           (Seq [Assign (Decl (Ptr . AsType $ class_type_name cname, Var "this"))
                        (Cast (Ptr . AsType $ class_type_name cname) (Var "_a")),
                 (Switch (Var "_m" `Arrow` Nam "id")
                  (
                   task_dispatch_clause :
                   (if (A.isMainClass cdecl)
                    then pony_main_clause : (method_clauses $ filter ((/= ID.Name "main") . A.mname) methods)
                    else method_clauses $ methods
                   ))
                  (Statement $ Call (Nam "printf") [String "error, got invalid id: %zd", AsExpr $ (Var "_m") `Arrow` (Nam "id")]))]))
           where
             pony_main_clause =
                 (Nam "_ENC__MSG_MAIN",
                  Seq $ [Assign (Decl (Ptr $ Typ "pony_main_msg_t", Var "msg")) (Cast (Ptr $ Typ "pony_main_msg_t") (Var "_m")),
                         Statement $ Call ((method_impl_name (Ty.refType "Main") (ID.Name "main")))
                                          [(Cast (Ptr $ Typ "_enc__active_Main_t") (Var "_a")),
                                           AsExpr $ (Var "msg") `Arrow` (Nam "argc"),
                                           AsExpr $ (Var "msg") `Arrow` (Nam "argv")]])

             method_clauses = concatMap method_clause

             method_clause m = (mthd_dispatch_clause m) :
                               if not (A.isStreamMethod m)
                               then [one_way_send_dispatch_clause m]
                               else []

             -- explode _enc__Foo_bar_msg_t struct into variable names
             method_unpack_arguments :: A.MethodDecl -> CCode Ty -> [CCode Stat]
             method_unpack_arguments mdecl msg_type_name =
               zipWith unpack (A.mparams mdecl) [1..]
                 where
                   unpack :: A.ParamDecl -> Int -> CCode Stat
                   unpack A.Param{A.pname, A.ptype} n = (Assign (Decl (translate ptype, (arg_name pname))) ((Cast (msg_type_name) (Var "_m")) `Arrow` (Nam $ "f"++show n)))

             -- TODO: include GC
             -- TODO: pack in encore_arg_t the task, infering its type
             task_dispatch_clause :: (CCode Name, CCode Stat)
             task_dispatch_clause =
               let tmp = Var "task_tmp"
                   task_runner = Statement $ Call (Nam "task_runner") [Var "_task"]
                   decl = Assign (Decl (encore_arg_t, tmp)) task_runner
                   future_fulfil = Statement $ Call (Nam "future_fulfil") [AsExpr $ Var "_fut", AsExpr tmp]
                   task_free = Statement $ Call (Nam "task_free") [AsExpr $ Var "_task"]
                   trace_future = Statement $ Call (Nam "pony_traceobject") [Var "_fut", future_type_rec_name `Dot` Nam "trace"]
                   trace_task = Statement $ Call (Nam "pony_traceobject") [Var "_task", AsLval $ Nam "NULL"]
               in
               (task_msg_id, Seq $ [unpack_future, unpack_task, decl] ++
                                   [Embed $ "",
                                    Embed $ "// --- GC on receiving ----------------------------------------",
                                    Statement $ Call (Nam "pony_gc_recv") ([] :: [CCode Expr]),
                                    trace_future,
                                    trace_task,
                                    Embed $ "//---You need to trace the task env and task dependencies---",
                                    Statement $ Call (Nam "pony_recv_done") ([] :: [CCode Expr]),
                                    Embed $ "// --- GC on sending ----------------------------------------",
                                    Embed $ ""]++
                             [future_fulfil, task_free])


             mthd_dispatch_clause mdecl@(A.Method{A.mname, A.mparams, A.mtype})  =
                (fut_msg_id cname mname,
                 Seq (unpack_future :
                      ((method_unpack_arguments mdecl (Ptr . AsType $ fut_msg_type_name cname mname)) ++
                      gc_recv mparams (Statement $ Call (Nam "pony_traceobject") [Var "_fut", future_type_rec_name `Dot` Nam "trace"]) ++
                      [Statement $ Call (Nam "future_fulfil")
                                        [AsExpr $ Var "_fut",
                                         as_encore_arg_t (translate mtype)
                                              (Call (method_impl_name cname mname)
                                              ((Var $ "this") :
                                              (map (arg_name . A.pname) mparams)))]])))
             mthd_dispatch_clause mdecl@(A.StreamMethod{A.mname, A.mparams})  =
                (fut_msg_id cname mname,
                 Seq (unpack_future :
                      ((method_unpack_arguments mdecl (Ptr . AsType $ fut_msg_type_name cname mname)) ++
                      gc_recv mparams (Statement $ Call (Nam "pony_traceobject") [Var "_fut", future_type_rec_name `Dot` Nam "trace"]) ++
                      [Statement $ Call (method_impl_name cname mname)
                                         ((Var $ "this") :
                                          (Var $ "_fut") :
                                          (map (arg_name . A.pname) mparams))])))

             one_way_send_dispatch_clause mdecl@A.Method{A.mname, A.mparams} =
                (one_way_msg_id cname mname,
                 Seq ((method_unpack_arguments mdecl (Ptr . AsType $ one_way_msg_type_name cname mname)) ++
                     gc_recv mparams (Comm "Not tracing the future in a one_way send") ++
                     [Statement $ Call (method_impl_name cname mname) ((Var $ "this") : (map (arg_name . A.pname) mparams))]))

             unpack_future = let lval = Decl (Ptr (Typ "future_t"), Var "_fut")
                                 rval = (Cast (Ptr $ enc_msg_t) (Var "_m")) `Arrow` (Nam "_fut")
                             in Assign lval rval

             unpack_task = let lval = Decl (task, Var "_task")
                               rval = (Cast (Ptr task_msg_t) (Var "_m")) `Arrow` (Nam "_task")
                           in Assign lval rval

             gc_recv ps fut_trace = [Embed $ "",
                                     Embed $ "// --- GC on receive ----------------------------------------",
                                     Statement $ Call (Nam "pony_gc_recv") ([] :: [CCode Expr])] ++
                                    (map trace_each_param ps) ++
                                    [fut_trace,
                                     Statement $ Call (Nam "pony_recv_done") ([] :: [CCode Expr]),
                                     Embed $ "// --- GC on receive ----------------------------------------",
                                     Embed $ ""]

             trace_each_param A.Param{A.pname, A.ptype} =
               Statement $ trace_variable ptype $ arg_name pname

-- | Translates a passive class into its C representation. Note
-- that there are additional declarations (including the data
-- struct for instance variables) in the file generated by
-- "CodeGen.Header"
translatePassiveClass cdecl@(A.Class{A.cname, A.fields, A.methods}) ctable =
    Program $ Concat $
      (LocalInclude "header.h") :
      [runtime_type_init_fun_decl cdecl] ++
      [tracefun_decl cdecl] ++
      method_impls ++
      [dispatchfun_decl] ++
      [runtime_type_decl cname]

    where
      method_impls = map method_decl methods
          where
            method_decl mdecl = translate mdecl cdecl ctable
      dispatchfun_decl =
          Function (Static void) (class_dispatch_name cname)
                   [(Ptr pony_actor_t, Var "_a"),
                    (Ptr pony_msg_t, Var "_m")]
                   (Comm "Stub! Might be used when we have dynamic dispatch on passive classes")

runtime_type_init_fun_decl :: A.ClassDecl -> CCode Toplevel
runtime_type_init_fun_decl A.Class{A.cname, A.fields, A.methods} =
    Function void (runtime_type_init_fn_name cname)
                 [(Ptr . AsType $ class_type_name cname, Var "this"), (Embed "...", Embed "")]
                   (Seq $
                    (Statement $ Decl (Typ "va_list", Var "params")) :
                    (Statement $ Call (Nam "va_start") [Var "params", Var "this"]) :
                     map (init_runtime_type) typeParams)
        where
          typeParams = Ty.getTypeParameters cname
          init_runtime_type ty =
              Assign (Var "this" `Arrow` type_var_ref_name ty)
                     (Call (Nam "va_arg") [Var "params", Var "pony_type_t *"])

tracefun_decl :: A.ClassDecl -> CCode Toplevel
tracefun_decl A.Class{A.cname, A.fields, A.methods} =
    case find ((== Ty.getId cname ++ "_trace") . show . A.mname) methods of
      Just mdecl@(A.Method{A.mbody, A.mname}) ->
          Function void (class_trace_fn_name cname)
                   [(Ptr void, Var "p")]
                   (Statement $ Call (method_impl_name cname mname)
                                [Var "p"])
      Nothing ->
          Function void (class_trace_fn_name cname)
                   [(Ptr void, Var "p")]
                   (Seq $
                    (Assign (Decl (Ptr . AsType $ class_type_name cname, Var "this"))
                            (Var "p")) :
                     map (Statement . trace_field) fields)
    where
      trace_field A.Field {A.ftype, A.fname} =
        let field = (Var "this") `Arrow` (field_name fname)
        in trace_variable ftype field

trace_variable :: Ty.Type -> CCode Lval -> CCode Expr
trace_variable t var
  | Ty.isActiveRefType  t = pony_traceactor var
  | Ty.isPassiveRefType t = pony_traceobject var (AsExpr . AsLval $ class_trace_fn_name t)
  | Ty.isFutureType     t = pony_traceobject var (AsExpr . AsLval $ future_trace_fn)
  | Ty.isArrowType      t = pony_traceobject var (AsExpr . AsLval $ closure_trace_fn)
  | Ty.isArrayType      t = pony_traceobject var (AsExpr . AsLval $ array_trace_fn)
  | Ty.isStreamType     t = pony_traceobject var (AsExpr . AsLval $ stream_trace_fn)
  | Ty.isTypeVar        t = trace_type_var t (var `Dot` (Nam "p"))
  | otherwise =
    Embed $ "/* Not tracing field '" ++ show var ++ "' */"

pony_traceactor :: CCode Lval -> CCode Expr
pony_traceactor var =
  Call (Nam "pony_traceactor")  [Cast (Ptr pony_actor_t) var]

pony_traceobject :: CCode Lval -> CCode Expr -> CCode Expr
pony_traceobject var f =
  Call (Nam "pony_traceobject")  [Cast (Ptr void) var, f]

trace_type_var :: Ty.Type -> CCode Lval -> CCode Expr
trace_type_var t val =
    let runtime_type = (Var "this" `Arrow` type_var_ref_name t) in
    If (BinOp (Nam "==") runtime_type (Var "ENCORE_PRIMITIVE"))
       (Embed $ "/* Not tracing field '" ++ show val ++ "' */")
       (Statement (If (BinOp (Nam "==") runtime_type (Var "ENCORE_ACTIVE"))
                      (Statement (pony_traceactor val))
                      (Statement (pony_traceobject val (AsExpr $ runtime_type `Arrow` Nam "trace")))))

runtime_type_decl cname =
    (AssignTL
     (Decl (Typ "pony_type_t", AsLval $ runtime_type_name cname))
           (Record [AsExpr . AsLval $ class_id cname,
                    Call (Nam "sizeof") [AsLval $ class_type_name cname],
                    Int 0,
                    Int 0,
                    AsExpr . AsLval $ (class_trace_fn_name cname),
                    Null,
                    Null,
                    AsExpr . AsLval $ class_dispatch_name cname,
                    Null]))
