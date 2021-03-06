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

(defpackage :http-pool.system
  (:use :cl :asdf))

(in-package :http-pool.system)

(defsystem :http-pool
  :name "http-pool"
  :author "Thomas de Grivel <billitch@gmail.com>"
  :version "0.1"
  :description "Parallel HTTP requests"
  :depends-on ("alexandria"
	       "chunga"
	       "cl-log"
	       "cl-ppcre"
	       "drakma"
	       "flexi-streams"
	       "trivial-http"
	       "trivial-utf-8")
  :components
  ((:file "http-pool")))
