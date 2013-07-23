;; https://github.com/bobbysmith007/my-lisp-build-scripts/blob/master/run-builds.lisp
(in-package :cl-user)
(require 'asdf)

;; load quicklisp
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp"
                                       (truename "."))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))

(asdf:initialize-source-registry
     `(:source-registry (:directory ,(truename "."))
                        :inherit-configuration))

(defmacro with-load-system-error-handling (() &body body)
  `(let ((recompile-count 0)
         (retry-count 0))
     (flet ((standard-error-handling (c)
              (when (and (< recompile-count 5)
                         (find-restart 'asdf:try-recompiling))
                (incf recompile-count)
                (invoke-restart 'asdf:try-recompiling))
              (when (and (< retry-count 5)
                         (find-restart 'asdf:retry))
                (incf retry-count)
                (invoke-restart 'asdf:retry))
              (format t "~S:~A~%~S~%~S~% after ~A recompile attempts and after ~A retry attempts~%~%"
                      (type-of c)
                      c c
                      (compute-restarts)
                      recompile-count retry-count)))
       (handler-bind
           ((asdf:missing-dependency
             (lambda (c)
               (format t "~%~%ATTEMPTING TO LOAD MISSING DEP ~S WITH QUICKLISP~%~%"
                       (asdf::missing-requires c))
               (quicklisp:quickload (asdf::missing-requires c))
               (standard-error-handling c)))
            (error #'standard-error-handling))
         ,@body
         ))))

(defun load-system (system)
  (with-load-system-error-handling ()
    (asdf:load-system system)))

(load-system 'munin)

(quit)
