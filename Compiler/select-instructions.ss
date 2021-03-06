(library (Compiler select-instructions)
  (export select-instructions)
  (import (chezscheme) (Framework helpers) (Framework match) (Compiler helpers))
  (define-who (select-instructions x)
    (define-who (Body body)
      (define new-ulocal* '())
      (define (new-u)
        (let ([u (unique-name 'u)])
          (set! new-ulocal* (cons u new-ulocal*))
          u))
      (define (select-move lhs rhs)
        (if (frame-var? lhs)
            (cond
             ((or (and (int64? rhs) (not (int32? rhs))) (frame-var? rhs) (label? rhs))
              (let ([u (new-u)])
                (make-begin `((set! ,u ,rhs) (set! ,lhs ,u)))))
             (else `(set! ,lhs ,rhs)))
            `(set! ,lhs ,rhs)))
      (define (bind-mem pred xpr value?)
        (if (pred xpr) (values xpr '())
            (let ([u (new-u)])
              (values u (if value? `((set! ,xpr ,u)) `((set! ,u ,xpr)))))))
      (define (select-mset! base off exp)
        (let-values ([(bexp brest) (bind-mem (lambda (x) (ur? x)) base #f)]
                     [(oexp orest) (bind-mem (lambda (x) (or (int32? x) (uvar? x))) off #f)]
                     [(eexp erest) (bind-mem (lambda (x) (or (int32? x) (ur? x))) exp #f)])
          (make-begin `(,@brest ,@orest ,@erest (mset! ,bexp ,oexp ,eexp)))))
      (define (select-mref var base off)
        (let-values ([(vexp vrest) (bind-mem (lambda (x) (ur? x)) var #t)]
                     [(bexp brest) (bind-mem (lambda (x) (ur? x)) base #f)]
                     [(oexp orest) (bind-mem (lambda (x) (or (int32? x) (uvar? x))) off #f)])
          (make-begin `(,@brest ,@orest (set! ,vexp (mref ,bexp ,oexp)) ,@vrest))))
      (define (select-binop x op y z)
        (if (eq? x y) (select-binop-2 x op z)
            (if (and (eq? x z) (memq op (list 'logand 'logor '+ '*)))
                (select-binop-2 x op y)
                (let ([u (new-u)])
                  (make-begin `((set! ,u ,y) ,(select-binop-2 u op z) (set! ,x ,u)))))))
      (define (select-binop-2 x op y)
        (case op
          ((+ - logand logor)
           (if (or (and (int64? y) (not (int32? y)))
                   (and (frame-var? x) (frame-var? y)))
               (let ([u (new-u)])
                 (make-begin `((set! ,u ,y) (set! ,x (,op ,x ,u)))))
               `(set! ,x (,op ,x ,y))))
          ((*)
           (if (frame-var? x)
               (let ([u (new-u)])
                 `(begin (set! ,u ,x) ,(select-binop-2 u op y) (set! ,x ,u)))
               (if (and (int64? y)(not (int32? y)))
                   (let ([u (new-u)])
                     (make-begin `((set! ,u ,y) (set! ,x (,op ,x ,u)))))
                   `(set! ,x (,op ,x ,y)))))
          ((sra) `(set! ,x (,op ,x ,y)))))
      (define (relop-inv op) (case op ((<) '>) ((<=) '>=) ((=) '=) ((>=) '<=) ((>) '<)))
      (define (select-relop op x y)
        (if (or (ur? x) (frame-var? x)) (select-relop-2 op x y)
            (if (or (ur? y) (frame-var? y)) (select-relop-2 (relop-inv op) y x)
                (let ([u (new-u)])
                  (make-begin `((set! ,u ,x) ,(select-relop-2 op u y)))))))
      (define (select-relop-2 op x y)
        (if (or (and (int64? y) (not (int32? y))) (and (frame-var? x) (frame-var? y)))
            (let ([u (new-u)])
              (make-begin `((set! ,u ,y) (,op ,x ,u))))
            `(,op ,x ,y)))
      (define (Effect effect)
        (match effect
          ((begin ,[Effect -> eff*] ... ,[eff]) (make-begin `(,@eff* ,eff)))
          ((if ,[Pred -> pred] ,[c] ,[a]) `(if ,pred ,c ,a))
          ((set! ,var (mref ,base ,off)) (select-mref var base off))
          ((set! ,x (,binop ,y ,z)) (select-binop x binop y z))
          ((set! ,lhs ,rhs) (select-move lhs rhs))
          ((mset! ,base ,off ,exp) (select-mset! base off exp))
          ((return-point ,label ,[Tail -> tail]) `(return-point ,label ,tail))
          (,x x)))
      (define (Pred pred)
        (match pred
          ((begin ,[Effect -> eff*] ... ,[pred]) (make-begin `(,@eff* ,pred)))
          ((if ,[pred] ,[c] ,[a]) `(if ,pred ,c ,a))
          ((,relop ,x ,y) (select-relop relop x y))
          (,x x)))
      (define (Tail tail)
        (match tail
          ((begin ,[Effect -> eff*] ... ,[tail]) (make-begin `(,@eff* ,tail)))
          ((if ,[Pred -> test] ,[consq] ,[altr]) `(if ,test ,consq ,altr))
          (,x x)))
      (match body
        ((locals (,local* ...)
           (ulocals (,ulocal* ...)
             (locate (,home* ...)
               (frame-conflict ,ct-graph ,[Tail -> tail]))))
         `(locals (,@local*)
            (ulocals (,@ulocal* ,@new-ulocal*)
              (locate (,@home*)
                (frame-conflict ,ct-graph ,tail)))))
        ((locate (,home* ...) ,[Tail -> tail]) `(locate (,@home*) ,tail))))
    (match x
      ((letrec ((,label* (lambda () ,[Body -> body*])) ...) ,[Body -> body])
       `(letrec ((,label* (lambda () ,body*)) ...) ,body)))))
