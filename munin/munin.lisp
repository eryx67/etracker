(require :asdf)
(require :sb-bsd-sockets)

(in-package #:munin)

(defvar *base-uri* "http://localhost:8080")
(defvar *base-uri-path* "/_stats")
(defvar *graph-title* "FOLSOM")
(defvar *version* "1.0.0")
(defvar *commands* '(:config :values))
(defvar *categories* '(:net :jobs :db))

(defun fetch-report (command category &key (uri *base-uri*) (title *graph-title*))
  (setq category (string-downcase category))

  (let ((info (request-info uri category)))
    (ecase command
      (:config (print-config category info title))
      (:values (print-values info (request-values uri category))))))

(defun print-metric-config (name info)
  (switch ((cdr (assoc "type" info :test #'equal)) :test #'equal)
    ("spiral" (format t "~a.label ~a~%" name name)
              (format t "~a.info per minute~%" name))
    (t (format t "~a.label ~a~%" name name)
       ;;(format t "~a.type COUNTER~%" name)
       )))

(defun print-metric-values (name info value)
  (switch ((cdr (assoc "type" info :test #'equal)) :test #'equal)
    ("spiral" (format t "~a.value ~a~%" name (cdr (assoc "one" value :test #'equal))))
    (t (format t "~a.value ~a~%" name value))))

(defun print-config (category info title)
  (format t "graph_category ~a~%" category)
  (format t "graph_title ~a ~a~%" title category)
  (format t "graph_vlabel value~%")
  (mapc #'(lambda (kv) (print-metric-config (car kv) (cdr kv))) info))

(defun print-values (info values)
  (mapc #'(lambda (ikv vkv)
            (print-metric-values (car ikv) (cdr ikv) (cdr vkv)))
        info values))

(defun request-info (uri category)
  (request-json uri category '(("info" . "true"))))

(defun request-values (uri category)
  (request-json uri category))

(defun uri-add-path (uri path)
  (let* ((uri (puri:uri uri))
         (uri-path (puri:uri-path uri)))
    (when (or (not uri-path)
              (equal uri-path "/"))
      (setq uri-path  *base-uri-path*))
    (puri:copy-uri uri :path (format nil "~{~a~^/~}"
                                     (list (string-right-trim "/" uri-path) path)))))

(defun request-json (uri &optional (path "") params)
  (multiple-value-bind (body status-code)
      (drakma:http-request (uri-add-path uri path)
                           :content-type "application/json"
                           :accept "application/json"
                           :parameters params)

    (labels ((convert-result (val)
               (typecase val
                 (hash-table (mapcar #'(lambda (kv)
                                         (cons (car kv) (convert-result (cdr kv))))
                                     (sort (hash-table-alist val) #'equal :key #'car)))
                 (list (mapcar #'convert-result val))
                 (t val))))
      (let ((body-str (and body
                           (babel:octets-to-string body :encoding :utf-8))))
        (case status-code
          (200 (convert-result (yason:parse body-str)))
          (t (error "invalid return code ~d, return body ~s" status-code body-str))
          )))
    ))

(eval-when (:execute :load-toplevel :compile-toplevel)
  (com.dvlsoft.clon:nickname-package))

(clon:defsynopsis (:postfix "[config]")
  (text :contents "FOLSOM plugin for Munin.")
  (stropt :short-name "u" :long-name "url"
          :argument-name "URL"
          :default-value *base-uri*
          :description "Server url"
          :env-var "folsom_url")
  (enum :short-name "c" :long-name "category"
        :enum *categories*
        :argument-name "CATEGORY"
        :default-value :db
        :description "Report category"
        :env-var "folsom_category")
  (stropt :short-name "t" :long-name "title"
          :argument-name "TITLE"
          :default-value *graph-title*
          :description "Report title"
          :env-var "folsom_report_title")
  (stropt :long-name "host-name"
          :argument-name "HOST-NAME"
          :description "Host name for plugin grouping"
          :env-var "folsom_host_name")

  (flag :short-name "h" :long-name "help"
        :description "Print this help and exit.")
  (flag :short-name "v" :long-name "version"
        :description "Print version number and exit."))

(defun runtime-debugger (condition previous-hook)
  (declare (ignore previous-hook))
  (format *error-output*
          "~&Fatal ~a: ~%  ~a~%" (type-of condition) condition)
  ;;(print (sb-debug:backtrace-as-list) *error-output*)
  (clon:exit -1))

(defun main (&optional argv)
  "Entry point for the standalone application."
  (declare (ignore argv))

  (setf sb-ext:*invoke-debugger-hook* 'runtime-debugger)
  (clon:make-context)
  (cond ((clon:getopt :short-name "h")
         (clon:help))
        ((clon:getopt :short-name "v")
         (pprint *version*)
         (fresh-line))
        (t
         (when (> (length (clon:remainder)) 1)
           (pprint "Only one command at time is allowed" *error-output*)
           (fresh-line)
           (clon:exit -1))

         (let* ((cmd-str (string-upcase (or (car (clon:remainder)) "values")))
                (cmd (progn (intern cmd-str :keyword)))
                (url (clon:getopt :short-name "u"))
                (category (clon:getopt :short-name "c"))
                (title (clon:getopt :short-name "t"))
                (host-name (clon:getopt :long-name "host-name")))

           (unless (member cmd *commands*)
             (error "Invalid command ~a" cmd))
           (when (and host-name
                      (eql cmd :config))
             (setf title (format nil "~a ~a" host-name title)))
           (fetch-report cmd category :uri url :title title)))
        (clon:exit)))
