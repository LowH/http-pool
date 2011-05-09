;;
;;  HTTP Pool  -  Parallel HTTP requests
;;
;;  Copyright 2011 Thomas de Grivel <billitch@gmail.com>
;;
;;  Permission to use, copy, modify, and distribute this software for
;;  any purpose with or without fee is hereby granted, provided that
;;  the above copyright notice and this permission notice appear in
;;  all copies.
;;
;;  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
;;  WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
;;  WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
;;  THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
;;  CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
;;  LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
;;  NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
;;  CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

(in-package :cl-user)

(defpackage :http-pool
  (:use :cl)
  (:export #:*debug*
	   #:sanitize-uri
	   #:make-query-string
	   #:http-probe
	   #:http-request
	   #:with-http-pool
	   #:http-pool-request
	   #:http-pool-parse-replies
	   #:http-error))

(in-package :http-pool)

(defvar *debug* nil)

;;  Error

(define-condition http-error (error)
  ((code :type integer :initform 500 :initarg :code)
   (msg  :type string :initform "Server error" :initarg :msg)))

(defun http-error (code format-control &rest format-args)
  (error 'http-error
	 :code code
	 :msg (format nil "HTTP ~D ~?" code format-control format-args)))

;;  URL

(defun sanitize-uri (uri)
  (declare (type simple-string uri))
  (with-output-to-string (out nil :element-type 'base-char)
    (dotimes (i (length uri))
      (let* ((c (char uri i))
	     (code (char-code c)))
	(cond ((<= code #x001f)
	       nil)
	      ((>= code #x0080)
	       (map nil (lambda (b)
			  (declare (type (unsigned-byte 8) b))
			  (format out "%~2,'0x" b))
		    (trivial-utf-8:string-to-utf-8-bytes
		     (make-string 1 :initial-element c))))
	      (t
	       (write-char c out)))))))

(defun make-query-string (plist)
  (drakma::alist-to-url-encoded-string
   (alexandria:plist-alist
    (mapcar (lambda (p)
	      (let ((*print-case* :downcase))
		(format nil "~A" p)))
	    plist))
   :utf-8))

;;  Simple HTTP requests

(defun http-probe (url)
  (ignore-errors
    (= 200 (the fixnum (first (trivial-http:http-head
			       (sanitize-uri url)))))))

(defun http-request (method url &optional post-params)
  (apply #'resolve
	 method
	 (ecase method
	   ((:get) (trivial-http:http-get (sanitize-uri url)))
	   ((:post) (trivial-http:http-post
		     (sanitize-uri url)
		     "application/x-www-form-urlencoded"
		     (make-query-string post-params))))))

;;  HTTP response

(defun wrap-stream (stream &optional (charset :latin-1))
  (flexi-streams:make-flexi-stream
   (chunga:make-chunked-stream stream)
   :external-format (flexi-streams:make-external-format
		     charset :eol-style :lf)))

(defun resolve (method code headers stream)
  "Returns list STREAM HEADERS"
  (let ((content-type (cdr (assoc :content-type headers))))
    (cl-ppcre:register-groups-bind (nil nil charset?)
	("([^\\s;]*)(;\\s*charset=([^\\s]+))?" content-type)
      (let ((charset (or (find-symbol (string-upcase charset?)
				      :keyword)
			 :latin-1))
	    (location (cdr (assoc :location headers))))
	(when *debug*
	  (format t "~&~%resolve :charset? ~S :charset ~S~%"
		  charset? charset))
	(case code
	  ((200) (list (wrap-stream stream charset) headers))
	  ((302) (destructuring-bind (code+ headers+ stream+ actual-url)
		     (trivial-http:http-resolve
		      location
		      :http-method (ecase method
				     ((:get) 'trivial-http::http-get)
				     ((:post) 'trivial-http::http-post)))
		   (declare (ignore actual-url))
		   (assert (= 200 (the fixnum code+)))
		   (list (wrap-stream stream+ charset) headers+)))
	  (:otherwise (http-error code "resolving ~S" location)))))))

;;  Pooled HTTP requests

(defstruct pool-entry state socket continuations)

(defvar *http-pool* nil "
Pool of HTTP requests.
Keys are of the form (METHOD URL) where method can be :GET or :POST.
")

(defmacro with-http-pool (&body body)
  `(let ((*http-pool* (make-hash-table :test 'equal)))
     (unwind-protect
	  (progn ,@body)
       (maphash (lambda (k e)
		  (declare (ignore k))
		  (usocket:socket-close (pool-entry-socket e)))
		*http-pool*))))

(defun http-pool-request (method url continuation &optional post-params)
  "Register a continuation in the request pool"
  (declare (type function continuation)
	   (type (member :get :post) method))
  (let* ((url (sanitize-uri url))
	 (key `(,method ,url ,post-params))
	 (entry (gethash key *http-pool*)))
    (cond (entry
	   (when *debug*
	     (format t "~&http-pool-request ADD ~S ~S~%"
		     key continuation))
	   (assert (eq :request-sent (pool-entry-state entry)))
	   (push continuation (pool-entry-continuations entry))
	   entry)
	  (t
	   (when *debug*
	     (format t "~&http-pool-request CREATE ~S ~S~%"
		     key continuation))
	   (setf (gethash key *http-pool*)
		 (make-pool-entry
		  :state :request-sent
		  :socket (ecase method
			    ((:get) (trivial-http:http-get
				     url
				     :request-only t))
			    ((:post) (trivial-http:http-post
				      url
				      "application/x-www-form-urlencoded"
				      (make-query-string post-params)
				      :request-only t)))
		  :continuations (list continuation)))))))

(defun http-pool-parse-replies (parse-fn)
  "
PARSE-FN takes STREAM and HEADERS and returns RESULT.
Each pooled continuation is then applied to RESULT
"
  (declare (type function parse-fn))
  (maphash
   (lambda (k e)
     (destructuring-bind (method url post-params) k
       (declare (ignorable url post-params))
       (assert (eq :request-sent (pool-entry-state e)))
       (setf (pool-entry-state e) :parsed)
       (let ((result (apply parse-fn
			    (apply #'resolve
				   method
				   (trivial-http:http-read-response
				    (pool-entry-socket e))))))
	 (when *debug*
	   (format t "~&http-pool-parse-replies ~S ~S -> ~S~%"
		   k e result))
	 (mapcar (lambda (c)
		   (declare (type function c))
		   (apply c result))
		 (pool-entry-continuations e)))))
   *http-pool*))
