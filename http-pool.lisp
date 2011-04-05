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

(defpackage :http-pool
  (:use :cl)
  (:export #:with-http-pool
	   #:http-pool-request
	   #:http-pool-parse))

(in-package :http-pool)

;;  URL

(defun make-query-string (plist)
  (drakma::alist-to-url-encoded-string
   (alexandria:plist-alist
    (mapcar (lambda (p)
	      (let ((*print-case* :downcase))
		(format nil "~A" p)))
	    plist))
   :latin-1))

;;  HTTP Request

(defun http-probe (url)
  (ignore-errors
    (= 200 (the fixnum (first (trivial-http:http-head url))))))

;;  HTTP response

(defun wrap-stream (stream)
  (flexi-streams:make-flexi-stream
   (chunga:make-chunked-stream stream)
   :external-format drakma::+latin-1+))

(defun http-stream (socket &optional (method :get))
  (multiple-value-bind (code headers stream)
      (trivial-http:http-read-response socket)
    (ecase code
      ((200) (values (wrap-stream stream) headers))
      ((302) (destructuring-bind (code+ headers+ stream+ actual-url)
		 (trivial-http:http-resolve
		  (cdr (assoc :location headers))
		  :http-method (ecase method
				 ((:get) 'trivial-http::http-get)
				 ((:post) 'trivial-http::http-post)))
	       (declare (ignore actual-url))
	       (assert (= 200 (the fixnum code+)))
	       (values (wrap-stream stream+) headers+))))))

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
  (declare (type function continuation))
  (let* ((key `(,method ,url ,post-params))
	 (entry (gethash key *http-pool*)))
    (cond (entry
	   (assert (eq :request-sent (pool-entry-state entry)))
	   (push continuation (pool-entry-continuations entry))
	   entry)
	  (t
	   (setf (gethash key *http-pool*)
		 (make-pool-entry
		  :state :request-sent
		  :info (ecase method
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
PARSE-FN takes a STREAM and returns RESULT.
Each pooled continuation is then applied to RESULT
"
  (declare (type function parse-fn))
  (maphash
   (lambda (k e)
     (destructuring-bind (method url) k
       (declare (ignore url))
       (assert (eq :request-sent (pool-entry-state e)))
       (setf (pool-entry-state e) :parsed)
       (let ((result (funcall parse-fn
			      (http-stream (pool-entry-socket e) method))))
	 (mapcar (lambda (c)
		   (declare (type function c))
		   (apply c result))
		 (pool-entry-continuations e)))))
   *http-pool*))
