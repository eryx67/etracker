;;;; package.lisp

(defpackage #:munin
  (:use #:cl)
  (:import-from #:alexandria #:hash-table-alist
                #:switch)
  (:export #:main))
