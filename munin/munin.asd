(asdf:defsystem #:munin
  :serial t
  :description "DHTOR munin plugin"
  :author "Vladimir G. Sekissov <eryx67@gmail.com>"
  :license "BSD"
  :depends-on (#:drakma #:yason #:babel #:puri
                        #:alexandria #:com.dvlsoft.clon)
  :components ((:file "package")
               (:file "munin")))
