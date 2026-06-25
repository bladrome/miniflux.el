;;; miniflux.el --- Miniflux RSS client using elfeed UI -*- lexical-binding: t; -*-

;; Author: bladrome
;; Maintainer: bladrome
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (elfeed "3.4.1"))
;; Keywords: news, rss, miniflux
;; URL: https://github.com/bladrome/miniflux.el

;;; Commentary:
;; A Miniflux RSS client that integrates with elfeed's database and UI.
;; Fetches entries from a Miniflux server and stores them in elfeed's
;; database so you can use the full elfeed interface.
;;
;; Setup:
;;   (setq miniflux-server "https://your-miniflux.example.com")
;;   (setq miniflux-token "your-api-token")
;;   ;; or: (setq miniflux-username "user" miniflux-password "pass")
;;
;; Usage:
;;   M-x miniflux          — sync from server, then open elfeed
;;   M-x miniflux-sync     — sync only (background)
;;   M-x miniflux-retry-sync-failed — retry failed local pushes
;;
;; In elfeed-search-mode:
;;   G  — sync from Miniflux server and refresh
;;   g  — refresh from local database (revert)
;;   u  — mark as unread (syncs to Miniflux)
;;   r  — mark as read (syncs to Miniflux, non-evil)
;;   +  — add tag (e.g. + star to sync star to Miniflux)
;;   -  — remove tag

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'gv)
(require 'json)
(require 'parse-time)
(require 'subr-x)
(require 'url)
(require 'elfeed)

(declare-function elfeed-search "elfeed")
(declare-function elfeed-search-buffer "elfeed-search")
(declare-function elfeed-search-selected "elfeed-search")
(declare-function elfeed-search-set-filter "elfeed-search")
(declare-function elfeed-search-update "elfeed-search")
(declare-function elfeed-db-add "elfeed-db")
(declare-function elfeed-db-ensure "elfeed-db")
(declare-function elfeed-db-save "elfeed-db")
(declare-function elfeed-entry--create "elfeed-db")
(declare-function elfeed-feed--create "elfeed-db")

(defun miniflux--ensure-elfeed ()
  "Ensure elfeed is loaded and available."
  (unless (featurep 'elfeed)
    (require 'elfeed)))

;; ─── Setf expanders for elfeed-entry struct fields ───
;; When this file is byte-compiled without elfeed on the load path, the
;; `setf' macro cannot discover the cl-struct setters for elfeed-entry
;; accessors and instead generates a call to the function
;; \=(setf elfeed-entry-TAG) which does not exist at run time, causing
;; "Symbol's function definition is void: (setf elfeed-entry-tags)".
;; We work around this by pre-registering our own gv-setters that use
;; `aset' with the correct slot indices.
;;
;; elfeed-entry struct layout (from elfeed-db.el):
;;   [0] type-tag  [1] id  [2] title  [3] link  [4] date
;;   [5] content  [6] content-type  [7] enclosures  [8] tags
;;   [9] feed-id  [10] meta

(defun miniflux--set-entry-tags (entry tags)
  "Set elfeed ENTRY tags slot to TAGS."
  (aset entry 8 tags))

(defun miniflux--set-entry-title (entry title)
  "Set elfeed ENTRY title slot to TITLE."
  (aset entry 2 title))

(defun miniflux--set-entry-meta (entry meta)
  "Set elfeed ENTRY meta slot to META."
  (aset entry 10 meta))

(gv-define-setter elfeed-entry-tags (val entry)
  `(miniflux--set-entry-tags ,entry ,val))

(gv-define-setter elfeed-entry-title (val entry)
  `(miniflux--set-entry-title ,entry ,val))

(gv-define-setter elfeed-entry-meta (val entry)
  `(miniflux--set-entry-meta ,entry ,val))

;;; ─── Customization ───

(defgroup miniflux nil
  "Access to the Miniflux feed aggregator through Emacs."
  :group 'applications
  :link '(url-link "https://miniflux.app/"))

(defcustom miniflux-server "https://example.com"
  "The base URL for the Miniflux server."
  :type '(string)
  :group 'miniflux)

(defcustom miniflux-token ""
  "API token for the Miniflux server.
See https://miniflux.app/docs/api.html#authentication."
  :type '(string)
  :group 'miniflux)

(defcustom miniflux-username ""
  "Username for HTTP Basic Auth."
  :type '(string)
  :group 'miniflux)

(defcustom miniflux-password ""
  "Password for HTTP Basic Auth."
  :type '(string)
  :group 'miniflux)

(defcustom miniflux-sync-limit 200
  "Maximum number of entries to fetch per sync."
  :type '(integer)
  :group 'miniflux)

(defcustom miniflux-sync-star-tag 'star
  "Tag name used in elfeed for starred Miniflux entries."
  :type '(symbol)
  :group 'miniflux)

(defcustom miniflux-sync-failed-tag 'miniflux-sync-failed
  "Tag added to entries when a local change fails to push to Miniflux."
  :type '(symbol)
  :group 'miniflux)

(defcustom miniflux-sync-full-unread t
  "Non-nil means fetch all unread pages during sync."
  :type '(boolean)
  :group 'miniflux)

(defcustom miniflux-sync-full-starred t
  "Non-nil means fetch all starred pages during sync."
  :type '(boolean)
  :group 'miniflux)

(defcustom miniflux-sync-pages-limit 20
  "Maximum number of pages to fetch for each paginated sync query."
  :type '(integer)
  :group 'miniflux)

(defcustom miniflux-sync-incremental t
  "Non-nil means fetch recent entries changed since the last successful sync.
This only affects the recent batch.  Unread and starred reconciliation
still uses their dedicated queries."
  :type '(boolean)
  :group 'miniflux)

(defcustom miniflux-category-tag-prefix ""
  "Prefix used for Miniflux category tags in elfeed.
Using a namespace lets sync replace stale category tags without touching
unrelated user tags."
  :type '(string)
  :group 'miniflux)

(defcustom miniflux-web-entry-path "/unread/entry/%d"
  "Format string for opening an entry in the Miniflux web interface."
  :type '(string)
  :group 'miniflux)

(defcustom miniflux-web-feed-path "/feeds/%d/entries"
  "Format string for opening a feed in the Miniflux web interface."
  :type '(string)
  :group 'miniflux)

(defvar miniflux--sync-in-progress nil
  "Non-nil when a sync is running.")

(defvar miniflux-last-sync-time nil
  "Unix timestamp of the last successful Miniflux sync.")

;;; ─── HTTP ───

(defun miniflux--api-url (path)
  "Build full API URL from PATH."
  (let ((base (directory-file-name miniflux-server)))
    (concat base (if (string-suffix-p "/v1" base) "" "/v1") path)))

(defun miniflux--auth-headers ()
  "Return authentication headers."
  (if (not (string-empty-p miniflux-token))
      `(("X-Auth-Token" . ,miniflux-token))
    (when (and (not (string-empty-p miniflux-username))
               (not (string-empty-p miniflux-password)))
      `(("Authorization" . ,(concat "Basic "
                                    (base64-encode-string
                                     (concat miniflux-username ":" miniflux-password)
                                     t)))))))

(defun miniflux--http-status ()
  "Extract HTTP status code from the current URL buffer."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
      (string-to-number (match-string 1)))))

(defun miniflux--http-body ()
  "Return point at start of HTTP body, skipping headers."
  (save-excursion
    (goto-char (point-min))
    (or (and (search-forward "\r\n\r\n" nil t) (point))
        (and (search-forward "\n\n" nil t) (point)))))

(defun miniflux--decode-body (body-start)
  "Return decoded response body from BODY-START to buffer end."
  (decode-coding-string
   (string-to-unibyte
    (buffer-substring-no-properties body-start (point-max)))
   'utf-8))

(defun miniflux--json-error-message (body)
  "Extract a useful error message from JSON BODY, or nil."
  (condition-case nil
      (let ((data (json-read-from-string body)))
        (or (assoc-default 'error_message data)
            (assoc-default 'message data)
            (assoc-default 'error data)))
    (error nil)))

(defun miniflux--request-url (path params)
  "Build full request URL for PATH and PARAMS."
  (let ((url (miniflux--api-url path)))
    (if params
        (concat url "?" (mapconcat
                         (lambda (p)
                           (format "%s=%s"
                                   (url-hexify-string (car p))
                                   (url-hexify-string (cdr p))))
                         params "&"))
      url)))

(defun miniflux--prepare-request (method data)
  "Set url.el dynamic request variables for METHOD and DATA."
  (setq url-request-method (format "%s" (substring (symbol-name method) 1))
        url-request-extra-headers (miniflux--auth-headers)
        url-request-data nil)
  (when (member method '(:POST :PUT))
    (push '("Content-Type" . "application/json") url-request-extra-headers)
    (when data
      (setq url-request-data (encode-coding-string (json-encode data) 'utf-8)))))

(defun miniflux--parse-response ()
  "Parse the current url.el response buffer."
  (let* ((body-start (miniflux--http-body))
         (status (miniflux--http-status)))
    (cond
     ((null body-start)
      (message "Miniflux: empty HTTP response")
      nil)
     ((or (null status) (>= status 400))
      (let* ((body (miniflux--decode-body body-start))
             (api-message (miniflux--json-error-message body)))
        (message "Miniflux HTTP %s%s"
                 (or status "?")
                 (if api-message (format ": %s" api-message) ""))
        nil))
     ((= status 204) t)
     (t
      (let ((body (miniflux--decode-body body-start)))
        (json-read-from-string body))))))

(defun miniflux--request (method path &optional data params)
  "Make a synchronous HTTP request to the Miniflux API.
METHOD: :GET :PUT :POST :DELETE.
PATH: API path (without /v1).
DATA: alist for JSON body.
PARAMS: alist for query string.
Returns parsed JSON on success, t for 204, nil on error."
  (let ((url (miniflux--request-url path params))
        (url-request-method nil)
        (url-request-extra-headers nil)
        (url-request-data nil))
    (condition-case err
        (progn
          (miniflux--prepare-request method data)
          (with-current-buffer (url-retrieve-synchronously url)
            (prog1
                (miniflux--parse-response)
              (kill-buffer (current-buffer)))))
      (error
       (message "Miniflux error: %S" (error-message-string err))
       nil))))

(defun miniflux--request-async (method path callback &optional data params)
  "Make an asynchronous HTTP request and call CALLBACK with parsed JSON."
  (let ((url (miniflux--request-url path params))
        (url-request-method nil)
        (url-request-extra-headers nil)
        (url-request-data nil))
    (miniflux--prepare-request method data)
    (url-retrieve
     url
     (lambda (status)
       (let ((buffer (current-buffer)))
         (unwind-protect
             (funcall callback
                      (if (plist-get status :error)
                          (progn
                            (message "Miniflux async error: %S" (plist-get status :error))
                            nil)
                        (condition-case err
                            (miniflux--parse-response)
                          (error
                           (message "Miniflux async parse error: %s" (error-message-string err))
                           nil))))
           (run-at-time 0.1 nil
                        (lambda (buf)
                          (when (buffer-live-p buf)
                            (kill-buffer buf)))
                        buffer)))))))

;;; ─── API: Feeds ───

(defun miniflux-get-feeds ()
  "Return list of all feeds."
  (miniflux--request :GET "/feeds"))

(defun miniflux-get-feed (id)
  "Return details for feed ID."
  (miniflux--request :GET (format "/feeds/%d" id)))

(defun miniflux-get-feed-entries (id &rest filters)
  "Return entries for feed ID with FILTERS plist."
  (miniflux--request :GET (format "/feeds/%d/entries" id)
                     nil (miniflux--filters-to-params filters)))

(defun miniflux-get-entries (&rest filters)
  "Return entries with FILTERS plist."
  (miniflux--request :GET "/entries" nil (miniflux--filters-to-params filters)))

(defun miniflux--filters-to-params (filters)
  "Convert FILTERS plist to API query params."
  (let (params)
    (while filters
      (let ((key (pop filters))
            (val (pop filters)))
        (when val
          (push (cons (substring (symbol-name key) 1) (format "%s" val)) params))))
    (nreverse params)))

(defun miniflux--fetch-entry-pages-async (filters full-p callback)
  "Fetch entry pages matching FILTERS asynchronously.
When FULL-P is non-nil, continue until the API total is exhausted or
`miniflux-sync-pages-limit' is reached.  Call CALLBACK with
(ENTRIES COMPLETE-P TOTAL OK-P)."
  (let ((offset 0)
        (page 0)
        (limit (min miniflux-sync-limit 100))
        (entries nil)
        (total nil)
        (complete-p nil)
        (ok-p nil))
    (cl-labels
        ((done ()
           (funcall callback (list entries complete-p total ok-p)))
         (next ()
           (if (not (and (or (= page 0)
                             (and full-p total (< (length entries) total)))
                         (< page miniflux-sync-pages-limit)))
               (done)
             (miniflux--request-async
              :GET "/entries"
              (lambda (data)
                (setq page (1+ page))
                (if (not data)
                    (done)
                  (let ((page-entries (append (assoc-default 'entries data) nil)))
                    (setq ok-p t
                          total (assoc-default 'total data)
                          entries (append entries page-entries)
                          offset (+ offset (length page-entries)))
                    (if (or (not full-p)
                            (not total)
                            (>= (length entries) total)
                            (< (length page-entries) limit))
                        (progn
                          (setq complete-p (or (and total (>= (length entries) total))
                                               (< (length page-entries) limit)))
                          (done))
                      (next)))))
              nil
              (miniflux--filters-to-params
               (append filters (list :limit limit
                                     :offset offset)))))))
      (next))))

(defun miniflux-refresh-feed (id)
  "Refresh feed ID on the server."
  (miniflux--request :PUT (format "/feeds/%d/refresh" id)))

(defun miniflux-refresh-all-feeds ()
  "Refresh all feeds on the server."
  (miniflux--request :PUT "/feeds/refresh"))

(defun miniflux-mark-feed-as-read (id)
  "Mark all entries in feed ID as read."
  (miniflux--request :PUT (format "/feeds/%d/mark-all-as-read" id)))

;;; ─── API: Entries ───

(defun miniflux-update-entry-status (ids status)
  "Set entry IDS to STATUS (\"read\" / \"unread\")."
  (miniflux--request :PUT "/entries"
                     `((entry_ids . ,(vconcat ids))
                       (status . ,status))))

(defun miniflux-toggle-entry-bookmark (id)
  "Toggle starred status for entry ID."
  (miniflux--request :PUT (format "/entries/%d/bookmark" id)))

(defun miniflux-get-entry (id)
  "Return entry ID."
  (miniflux--request :GET (format "/entries/%d" id)))

;;; ─── API: Categories ───

(defun miniflux-get-categories ()
  "Return list of all categories."
  (miniflux--request :GET "/categories"))

(defun miniflux-mark-category-as-read (id)
  "Mark all entries in category ID as read."
  (miniflux--request :PUT (format "/categories/%d/mark-all-as-read" id)))

;;; ─── API: Counters ───

(defun miniflux--get-counters ()
  "Return alist of (feed-id . unread-count) for all feeds."
  (let ((data (miniflux--request :GET "/feeds/counters")))
    (when data
      (let ((fixer (lambda (x) (cons (read (symbol-name (car x))) (cdr x)))))
        (mapcar fixer (assoc-default 'unreads data))))))

;;; ─── Elfeed integration ───

(defun miniflux--check-auth ()
  "Check auth config and return t if OK."
  (cond
   ((not (string-empty-p miniflux-token)) t)
   ((and (not (string-empty-p miniflux-username))
         (not (string-empty-p miniflux-password))) t)
   (t
    (user-error "Set `miniflux-token' or `miniflux-username' + `miniflux-password'"))))

(defun miniflux--feed-url (feed-id)
  "Build a unique elfeed feed-id for Miniflux feed FEED-ID (number)."
  (format "miniflux://%d" feed-id))

(defun miniflux--parse-date (date-string)
  "Parse DATE-STRING to float-time, falling back to current time."
  (if (not date-string) (float-time)
    (condition-case nil
        (let ((time (float-time (encode-time (parse-time-string date-string)))))
          (if (< time 0) (float-time) time))
      (error (float-time)))))

(defun miniflux--format-time-rfc3339 (time)
  "Format unix TIME as an RFC3339 UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" (seconds-to-time time) t))

(defun miniflux--slugify (text)
  "Return a tag-safe slug for TEXT."
  (let ((slug (replace-regexp-in-string
               "[^[:alnum:]_-]+" "-"
               (downcase (string-trim (or text ""))))))
    (replace-regexp-in-string "\\`-+\\|-+\\'" "" slug)))

(defun miniflux--category-tag-p (tag)
  "Return non-nil if TAG is managed by miniflux category sync."
  (and (not (string-empty-p miniflux-category-tag-prefix))
       (string-prefix-p miniflux-category-tag-prefix (symbol-name tag))))

(defun miniflux--entry-category-tag (entry)
  "Return the Miniflux category title for ENTRY as a symbol, or nil."
  (let* ((feed-data (assoc-default 'feed entry))
         (category (assoc-default 'category feed-data))
         (cat-title (assoc-default 'title category)))
    (when (and cat-title (not (string-empty-p cat-title)))
      (intern (concat miniflux-category-tag-prefix (miniflux--slugify cat-title))))))

(defun miniflux--feed-meta (feed-data)
  "Build elfeed feed metadata from Miniflux FEED-DATA."
  (let* ((category (assoc-default 'category feed-data))
         (category-title (assoc-default 'title category)))
    `(,@(when (assoc-default 'site_url feed-data)
          (list :site-url (assoc-default 'site_url feed-data)))
      ,@(when (assoc-default 'feed_url feed-data)
          (list :feed-url (assoc-default 'feed_url feed-data)))
      ,@(when (assoc-default 'id category)
          (list :miniflux-category-id (assoc-default 'id category)))
      ,@(when category-title
          (list :miniflux-category-title category-title))
      ,@(when (assoc-default 'checked_at feed-data)
          (list :checked-at (assoc-default 'checked_at feed-data)))
      ,@(when (assoc-default 'next_check_at feed-data)
          (list :next-check-at (assoc-default 'next_check_at feed-data)))
      ,@(when (assoc-default 'parsing_error_message feed-data)
          (list :parsing-error-message
                (assoc-default 'parsing_error_message feed-data))))))

(defun miniflux--plist-merge (new old)
  "Return OLD plist updated with all key/value pairs from NEW."
  (let ((result (copy-sequence old)))
    (while new
      (setq result (plist-put result (pop new) (pop new))))
    result))

(defun miniflux--entry-meta (entry author)
  "Build elfeed entry metadata from Miniflux ENTRY and AUTHOR."
  (let* ((feed-data (assoc-default 'feed entry))
         (category (assoc-default 'category feed-data)))
    `(,@(when (and author (not (string-empty-p author)))
          (list :authors (list (list :name author))))
      :miniflux-id ,(assoc-default 'id entry)
      ,@(when (assoc-default 'id feed-data)
          (list :miniflux-feed-id (assoc-default 'id feed-data)))
      ,@(when (assoc-default 'id category)
          (list :miniflux-category-id (assoc-default 'id category)))
      ,@(when (assoc-default 'title category)
          (list :miniflux-category-title (assoc-default 'title category)))
      ,@(miniflux--feed-meta feed-data))))

(defun miniflux--entry-to-elfeed (entry feed-id-str)
  "Convert a Miniflux ENTRY alist to an elfeed-entry struct.
FEED-ID-STR is the elfeed feed id string (e.g. \"miniflux://5\")."
  (let* ((mf-id (assoc-default 'id entry))
         (title (or (assoc-default 'title entry) ""))
         (title (replace-regexp-in-string "[\n\r]+" " " title))
         (link (or (assoc-default 'url entry) ""))
         (pub-date (assoc-default 'published_at entry))
         (date-str (if (and pub-date (not (string-prefix-p "0001" pub-date)))
                       pub-date
                     (or (assoc-default 'changed_at entry)
                         (assoc-default 'created_at entry))))
         (date (miniflux--parse-date date-str))
         (content (or (assoc-default 'content entry) ""))
         (author (or (assoc-default 'author entry) ""))
         (status (assoc-default 'status entry))
         (starred (assoc-default 'starred entry))
         (entry-id (cons 'miniflux (format "%d" mf-id)))
         (cat-tag (miniflux--entry-category-tag entry))
         (tags (delq nil
                     (list (when (equal status "unread") 'unread)
                           (when (eq t starred) miniflux-sync-star-tag)
                           cat-tag))))
    (elfeed-entry--create
     :id entry-id
     :title title
     :link link
     :date date
      :content content
      :content-type 'html
      :tags tags
      :feed-id feed-id-str
      :meta (miniflux--entry-meta entry author))))

(defun miniflux--sync-entries (data feed-id-str)
  "Convert DATA entries and add them to the elfeed database.
FEED-ID-STR is the elfeed feed id."
  (let* ((raw-entries (assoc-default 'entries data))
         (elfeed-entries
          (when raw-entries
            (mapcar (lambda (e) (miniflux--entry-to-elfeed e feed-id-str))
                    raw-entries))))
    (when elfeed-entries
      (elfeed-db-add elfeed-entries))))

(defun miniflux--sync-feed (feed-id feed-title)
  "Sync entries for a single Miniflux FEED-ID with FEED-TITLE."
  (let* ((feed-id-str (miniflux--feed-url feed-id))
         (feed-title (or feed-title (format "Feed %d" feed-id)))
         (data (miniflux-get-feed-entries feed-id :limit miniflux-sync-limit)))
    (elfeed-db-ensure)
    (puthash feed-id-str
             (elfeed-feed--create :id feed-id-str :url feed-id-str :title feed-title)
             elfeed-db-feeds)
    (when data
      (miniflux--sync-entries data feed-id-str))))

(defun miniflux--build-feed-from-entry (entry)
  "Ensure elfeed feed object exists for the feed referenced by ENTRY."
  (let* ((feed-data (assoc-default 'feed entry))
          (feed-id (assoc-default 'id feed-data))
          (feed-title (or (assoc-default 'title feed-data) (format "Feed %d" feed-id)))
          (feed-id-str (miniflux--feed-url feed-id)))
     (elfeed-db-ensure)
     (puthash feed-id-str
              (elfeed-feed--create :id feed-id-str
                                   :url (or (assoc-default 'site_url feed-data)
                                            (assoc-default 'feed_url feed-data)
                                            feed-id-str)
                                   :title feed-title)
              elfeed-db-feeds)
     feed-id-str))

(defun miniflux--convert-entries (raw-entries)
  "Convert RAW-ENTRIES from Miniflux API to elfeed entries and add to DB."
  (let (elfeed-entries)
    (mapc (lambda (e)
            (let ((feed-id-str (miniflux--build-feed-from-entry e)))
              (push (miniflux--entry-to-elfeed e feed-id-str) elfeed-entries)))
          (append raw-entries nil))
    (elfeed-db-add elfeed-entries)))

;; NOTE: There is intentionally NO push step during sync.
;;
;; Previous implementations tried to push local tag changes back to the
;; Miniflux server during sync.  This caused a critical bug: local-only
;; stars (from old DB entries, failed hooks, etc.) were re-pushed to the
;; server, inflating the remote starred count.  The reconciliation then
;; saw the inflated set and kept all local stars — making sync a no-op.
;;
;; The correct design is: sync is PULL-ONLY.  The server is the single
;; source of truth.  Real-time tag hooks (elfeed-tag/elfeed-untag)
;; handle local→server pushes immediately when the user makes changes.
;; If a hook fails (network error), the local change is lost on next
;; sync — this is the standard behavior for multi-device RSS clients.

(defun miniflux--fetch-and-store (filters)
  "Fetch entries with FILTERS plist, add to elfeed DB, return raw entries list."
  (let ((data (apply #'miniflux-get-entries filters)))
    (when data
      (let ((entries (assoc-default 'entries data)))
        (when entries
          (miniflux--convert-entries entries)
          entries)))))

(defun miniflux--record-api-entry (entry api-table api-starred-ids api-unread-ids)
  "Record ENTRY state in sync hash tables."
  (let ((id (cons 'miniflux (format "%d" (assoc-default 'id entry)))))
    (puthash id entry api-table)
    (when (eq t (assoc-default 'starred entry))
      (puthash id t api-starred-ids))
    (when (equal (assoc-default 'status entry) "unread")
      (puthash id t api-unread-ids))))

(defun miniflux--store-and-record-entries (entries api-table api-starred-ids api-unread-ids)
  "Store ENTRIES in elfeed and update sync hash tables."
  (when entries
    (miniflux--convert-entries entries)
    (dolist (entry entries)
      (miniflux--record-api-entry entry api-table api-starred-ids api-unread-ids)))
  (length entries))

(defun miniflux--store-sync-result (result api-table api-starred-ids api-unread-ids)
  "Store entries from fetch RESULT and return (COUNT COMPLETE-P OK-P)."
  (list (miniflux--store-and-record-entries
         (nth 0 result) api-table api-starred-ids api-unread-ids)
        (nth 1 result)
        (nth 3 result)))

(defun miniflux--recent-sync-filters ()
  "Return filters for the recent entries sync batch."
  (append (list :order "published_at")
          (when (and miniflux-sync-incremental miniflux-last-sync-time)
            (list :after (miniflux--format-time-rfc3339 miniflux-last-sync-time)))))

(defun miniflux--finish-sync (api-table api-starred-ids api-unread-ids
                                        starred-batch-complete unread-batch-complete
                                        ok-count total-entries)
  "Reconcile and save sync state, then return TOTAL-ENTRIES."
  (let ((star-changes (miniflux--reconcile-all-stars
                       api-starred-ids starred-batch-complete)))
    (when (> star-changes 0)
      (message "Miniflux: reconciled %d star tag(s)" star-changes)))
  (let ((unread-changes (miniflux--reconcile-all-unread
                         api-unread-ids unread-batch-complete)))
    (when (> unread-changes 0)
      (message "Miniflux: reconciled %d unread tag(s)" unread-changes)))
  (miniflux--reconcile-entry-tags api-table)
  (elfeed-db-save)
  (when (> ok-count 0)
    (setq miniflux-last-sync-time (float-time)))
  (if (> total-entries 0)
      (message "Miniflux: synced %d entries" total-entries)
    (message "Miniflux: no entries found (check server/credentials)"))
  total-entries)

(defun miniflux--perform-sync-async (callback)
  "Perform the Miniflux -> elfeed sync asynchronously.
Call CALLBACK with the stored entry count on success, or nil on failure."
  (message "Miniflux: syncing...")
  (let ((api-table (make-hash-table :test 'equal))
        (api-starred-ids (make-hash-table :test 'equal))
        (api-unread-ids (make-hash-table :test 'equal))
        (starred-batch-complete nil)
        (unread-batch-complete nil)
        (ok-count 0)
        (total-entries 0))
    (cl-labels
        ((store-result (result)
           (let ((stored (miniflux--store-sync-result
                          result api-table api-starred-ids api-unread-ids)))
             (setq total-entries (+ total-entries (nth 0 stored)))
             (when (nth 2 stored)
               (setq ok-count (1+ ok-count)))
             (nth 1 stored)))
         (fail (err)
           (message "Miniflux async sync error: %s" (error-message-string err))
           (funcall callback nil))
         (finish ()
           (condition-case err
               (funcall callback
                        (miniflux--finish-sync api-table api-starred-ids api-unread-ids
                                               starred-batch-complete unread-batch-complete
                                               ok-count total-entries))
             (error (fail err))))
         (fetch-unread ()
           (miniflux--fetch-entry-pages-async
            (list :status "unread") miniflux-sync-full-unread
            (lambda (result)
              (condition-case err
                  (progn
                    (setq unread-batch-complete (store-result result))
                    (finish))
                (error (fail err))))))
         (fetch-starred ()
           (miniflux--fetch-entry-pages-async
            (list :starred "1") miniflux-sync-full-starred
            (lambda (result)
              (condition-case err
                  (progn
                    (setq starred-batch-complete (store-result result))
                    (fetch-unread))
                (error (fail err))))))
         (fetch-recent ()
           (miniflux--fetch-entry-pages-async
            (miniflux--recent-sync-filters) nil
            (lambda (result)
              (condition-case err
                  (progn
                    (store-result result)
                    (fetch-starred))
                (error (fail err)))))))
      (fetch-recent))))

(defun miniflux--reconcile-all-stars (api-starred-ids complete-p)
  "Reconcile star tags for ALL local miniflux entries against the API.
API-STARRED-IDS is a hash table keyed by entry-id (cons) for entries
that are starred on the server.  COMPLETE-P is non-nil when the starred
batch was not full, meaning api-starred-ids is the complete set of
starred entries on the server.

When COMPLETE-P: iterates over every miniflux entry in
`elfeed-db-entries' and forces the local star tag to match the server.
When NOT COMPLETE-P: only adds star tags (entries in api-starred-ids
that lack it locally) but does not remove them (to avoid false negatives
from incomplete batches).

Returns the number of entries changed.

This uses (setf elfeed-entry-tags) which goes through our custom gv-setter
(miniflux--set-entry-tags / aset), NOT through elfeed-tag/elfeed-untag.
Therefore elfeed's tag hooks are NOT triggered and no API calls are made."
  (let ((changed 0))
    (maphash
     (lambda (id entry)
       (when (and (consp id) (eq (car id) 'miniflux))
         (let* ((tags (elfeed-entry-tags entry))
                (has-star (memq miniflux-sync-star-tag tags))
                (should-star (gethash id api-starred-ids)))
           (cond
             ;; Local has star, API doesn't -> remove only if batch complete
             ((and has-star (not should-star) complete-p)
              (setf (elfeed-entry-tags entry)
                    (delq miniflux-sync-star-tag tags))
              (setq changed (1+ changed)))
             ;; API has star, local doesn't -> add star
             ((and should-star (not has-star))
              (push miniflux-sync-star-tag tags)
              (setf (elfeed-entry-tags entry) tags)
              (setq changed (1+ changed)))))))
     elfeed-db-entries)
    changed))

(defun miniflux--reconcile-all-unread (api-unread-ids complete-p)
  "Reconcile unread tags for ALL local miniflux entries against the API.
API-UNREAD-IDS is a hash table keyed by entry-id (cons) for entries
that are unread on the server.  COMPLETE-P is non-nil when the unread
batch was not full, meaning api-unread-ids is the complete set of
unread entries on the server.

When COMPLETE-P: iterates ALL local miniflux entries and forces the
unread tag to match the server.  When NOT COMPLETE-P: only adds
unread tags (entries in api-unread-ids that lack it locally) but does
not remove them (to avoid false negatives from incomplete batches).

Uses (setf elfeed-entry-tags) → no elfeed hooks are triggered."
  (let ((changed 0))
    (maphash
     (lambda (id entry)
       (when (and (consp id) (eq (car id) 'miniflux))
         (let* ((tags (elfeed-entry-tags entry))
                (has-unread (memq 'unread tags))
                (should-unread (gethash id api-unread-ids)))
           (cond
             ;; API doesn't have unread, local does -> remove (only if batch complete)
             ((and has-unread (not should-unread) complete-p)
              (setf (elfeed-entry-tags entry)
                    (delq 'unread tags))
              (setq changed (1+ changed)))
             ;; API has unread, local doesn't -> add
             ((and should-unread (not has-unread))
              (setf (elfeed-entry-tags entry)
                    (cons 'unread tags))
              (setq changed (1+ changed)))))))
     elfeed-db-entries)
    changed))

(defun miniflux--reconcile-entry-tags (api-table)
  "Reconcile fetched entry metadata for entries present in API-TABLE.
API-TABLE maps entry-id (cons) to raw API entry alist.  For each local
entry found in API-TABLE, normalize multiline titles and ensure the
current Miniflux category tag exists locally.

This function deliberately preserves unrelated local tags.  Star
reconciliation is handled by `miniflux--reconcile-all-stars'.  Unread
reconciliation is handled by `miniflux--reconcile-all-unread'.

Uses direct (setf elfeed-entry-tags) -> no elfeed hooks are triggered."
  (maphash
   (lambda (id api-entry)
     (let* ((api-cat (miniflux--entry-category-tag api-entry))
            (e (gethash id elfeed-db-entries)))
       (when e
          ;; Fix titles with newlines
          (let ((title (elfeed-entry-title e)))
            (when (string-match-p "[\n\r]" title)
              (setf (elfeed-entry-title e)
                    (replace-regexp-in-string "[\n\r]+" " " title))))
           ;; Replace stale miniflux category tags without touching user tags.
           (let* ((tags (elfeed-entry-tags e))
                  (tags (cl-remove-if #'miniflux--category-tag-p
                                      (copy-sequence tags))))
              (when (and api-cat (not (memq api-cat tags)))
                (push api-cat tags))
              (setf (elfeed-entry-meta e)
                    (miniflux--plist-merge
                     (miniflux--entry-meta api-entry
                                           (or (assoc-default 'author api-entry) ""))
                     (elfeed-entry-meta e)))
              (setf (elfeed-entry-tags e) tags)))))
   api-table))

(defun miniflux-sync (&optional callback)
  "Sync entries from Miniflux server into elfeed's database.

Sync is PULL-ONLY — the server is the single source of truth.

Sync runs ASYNCHRONOUSLY via url.el's non-blocking HTTP requests, so
Emacs stays responsive while the server is contacted.  CALLBACK, if
non-nil, is invoked with the number of synced entries (or nil on
failure) once sync completes.  Local->server pushes happen in
real-time via elfeed tag hooks
(see `miniflux--tag-hook' / `miniflux--untag-hook').

Flow:
  1. Fetch starred, unread, and recent entries from the API.
  2. Add/update them in elfeed DB (elfeed-db-add preserves local tags
     for existing entries; reconciliation fixes them in step 4).
  3. Build api-starred-ids and api-unread-ids hash tables.
  4. Star reconciliation: iterate over local miniflux entries and force
     star tags to match api-starred-ids when the starred batch is complete.
  5. Unread reconciliation: iterate over ALL local miniflux entries
     and force unread tags to match api-unread-ids.
  6. Category reconciliation: for entries in api-table, sync category tags.
  7. Save."
  (interactive)
  (miniflux--check-auth)
  (miniflux--ensure-elfeed)
  (miniflux--install-hooks)
  (when miniflux--sync-in-progress
    (user-error "Sync already in progress"))
  (setq miniflux--sync-in-progress t)
  (condition-case err
      (miniflux--perform-sync-async
       (lambda (total)
         (unwind-protect
             (when (and callback (functionp callback))
               (funcall callback total))
           (setq miniflux--sync-in-progress nil))))
    (error
     (setq miniflux--sync-in-progress nil)
     (signal (car err) (cdr err))))
  (message "Miniflux: async sync started"))

(defun miniflux-sync-async ()
  "Start a non-blocking Miniflux sync and return immediately.
This is now an alias for `miniflux-sync' (which is asynchronous) plus
a refresh of the elfeed search buffer on completion.  Kept for
backward compatibility."
  (interactive)
  (miniflux-sync #'miniflux--refresh-search-maybe))

(defun miniflux--entry-mf-id (entry)
  "Get the Miniflux numeric ID from an elfeed ENTRY, or nil."
  (let ((id (elfeed-entry-id entry)))
    (when (and (consp id) (eq (car id) 'miniflux))
      (string-to-number (cdr id)))))

(defun miniflux--entry-mf-feed-id (entry)
  "Get the Miniflux numeric feed ID from an elfeed ENTRY, or nil."
  (let ((feed-id (elfeed-entry-feed-id entry)))
    (when (stringp feed-id)
      (save-match-data
        (when (string-match "\\`miniflux://\\([0-9]+\\)\\'" feed-id)
          (string-to-number (match-string 1 feed-id)))))))

(defun miniflux--selected-entries ()
  "Return selected elfeed entries in `elfeed-search-mode'."
  (miniflux--ensure-elfeed)
  (or (and (fboundp 'elfeed-search-selected)
           (elfeed-search-selected))
      (user-error "No elfeed entries selected")))

(defun miniflux--selected-entry ()
  "Return one selected elfeed entry."
  (car (miniflux--selected-entries)))

(defun miniflux--entry-category-id (entry)
  "Return Miniflux category id for ENTRY, or nil."
  (plist-get (elfeed-entry-meta entry) :miniflux-category-id))

(defun miniflux--mark-entries-sync-failed (entries)
  "Mark ENTRIES with `miniflux-sync-failed-tag'."
  (dolist (entry entries)
    (let ((tags (elfeed-entry-tags entry)))
      (unless (memq miniflux-sync-failed-tag tags)
        (setf (elfeed-entry-tags entry)
              (cons miniflux-sync-failed-tag tags))))))

(defun miniflux--clear-entries-sync-failed (entries)
  "Remove `miniflux-sync-failed-tag' from ENTRIES."
  (dolist (entry entries)
    (when (memq miniflux-sync-failed-tag (elfeed-entry-tags entry))
      (setf (elfeed-entry-tags entry)
            (delq miniflux-sync-failed-tag (elfeed-entry-tags entry))))))

(defun miniflux--entry-starred-p (entry)
  "Return non-nil if ENTRY has the configured Miniflux star tag."
  (memq miniflux-sync-star-tag (elfeed-entry-tags entry)))

(defun miniflux--push-entry-state (entry)
  "Push ENTRY's current unread/star state to Miniflux.
Return non-nil when all remote updates succeeded.  Bookmark state is
checked against the server before toggling because Miniflux exposes a
toggle endpoint rather than an explicit set endpoint."
  (let ((id (miniflux--entry-mf-id entry)))
    (when id
      (let* ((tags (elfeed-entry-tags entry))
             (want-unread (not (null (memq 'unread tags))))
             (want-starred (not (null (miniflux--entry-starred-p entry))))
             (status-ok (miniflux-update-entry-status
                         (list id) (if want-unread "unread" "read")))
             (remote-entry (and status-ok (miniflux-get-entry id)))
             (remote-starred (assoc-default 'starred remote-entry))
             (star-ok (and remote-entry
                           (or (eq want-starred remote-starred)
                               (miniflux-toggle-entry-bookmark id)))))
        (and status-ok star-ok)))))

(defun miniflux-retry-sync-failed ()
  "Retry pushing selected elfeed entries' local state to Miniflux.
This is intended for entries tagged with `miniflux-sync-failed-tag', but
it works on any selected Miniflux entries.  Entries that still fail keep
the failure tag; successfully pushed entries have it removed."
  (interactive nil elfeed-search-mode)
  (miniflux--check-auth)
  (let ((entries (miniflux--selected-entries))
        (ok 0)
        (failed 0))
    (dolist (entry entries)
      (condition-case err
          (if (miniflux--push-entry-state entry)
              (progn
                (miniflux--clear-entries-sync-failed (list entry))
                (setq ok (1+ ok)))
            (miniflux--mark-entries-sync-failed (list entry))
            (setq failed (1+ failed)))
        (error
         (miniflux--mark-entries-sync-failed (list entry))
         (setq failed (1+ failed))
         (message "Miniflux retry error: %s" (error-message-string err)))))
    (elfeed-db-save)
    (when (derived-mode-p 'elfeed-search-mode)
      (elfeed-search-update :force))
    (message "Miniflux: retried %d entr%s, %d succeeded, %d failed"
             (+ ok failed) (if (= (+ ok failed) 1) "y" "ies") ok failed)))

(defun miniflux-clear-sync-failed ()
  "Clear sync failure markers from selected elfeed entries."
  (interactive nil elfeed-search-mode)
  (miniflux--clear-entries-sync-failed (miniflux--selected-entries))
  (elfeed-db-save)
  (elfeed-search-update :force))

(defun miniflux--web-url (path-format id)
  "Build a Miniflux web URL from PATH-FORMAT and ID."
  (concat (directory-file-name miniflux-server) (format path-format id)))

(defun miniflux-open-entry-in-miniflux ()
  "Open the selected entry in the Miniflux web interface."
  (interactive nil elfeed-search-mode)
  (let ((id (miniflux--entry-mf-id (miniflux--selected-entry))))
    (unless id
      (user-error "Selected entry is not a Miniflux entry"))
    (browse-url (miniflux--web-url miniflux-web-entry-path id))))

(defun miniflux-open-feed-in-miniflux ()
  "Open the selected entry's feed in the Miniflux web interface."
  (interactive nil elfeed-search-mode)
  (let ((id (miniflux--entry-mf-feed-id (miniflux--selected-entry))))
    (unless id
      (user-error "Selected entry has no Miniflux feed id"))
    (browse-url (miniflux--web-url miniflux-web-feed-path id))))

(defun miniflux-refresh-current-feed ()
  "Refresh the selected entry's feed on the Miniflux server."
  (interactive nil elfeed-search-mode)
  (let ((id (miniflux--entry-mf-feed-id (miniflux--selected-entry))))
    (unless id
      (user-error "Selected entry has no Miniflux feed id"))
    (if (miniflux-refresh-feed id)
        (message "Miniflux: refreshed feed %d" id)
      (user-error "Miniflux: failed to refresh feed %d" id))))

(defun miniflux-mark-current-feed-read ()
  "Mark the selected entry's feed as read on Miniflux, then sync."
  (interactive nil elfeed-search-mode)
  (let ((id (miniflux--entry-mf-feed-id (miniflux--selected-entry))))
    (unless id
      (user-error "Selected entry has no Miniflux feed id"))
    (if (miniflux-mark-feed-as-read id)
        (miniflux-search-refresh)
      (user-error "Miniflux: failed to mark feed %d as read" id))))

(defun miniflux-mark-current-category-read ()
  "Mark the selected entry's category as read on Miniflux, then sync."
  (interactive nil elfeed-search-mode)
  (let ((id (miniflux--entry-category-id (miniflux--selected-entry))))
    (unless id
      (user-error "Selected entry has no Miniflux category id"))
    (if (miniflux-mark-category-as-read id)
        (miniflux-search-refresh)
      (user-error "Miniflux: failed to mark category %d as read" id))))

(defun miniflux-show-unread ()
  "Show unread Miniflux entries in elfeed search."
  (interactive)
  (miniflux--ensure-elfeed)
  (unless (get-buffer (elfeed-search-buffer))
    (elfeed-search))
  (elfeed-search-set-filter "+unread "))

(defun miniflux-show-starred ()
  "Show starred Miniflux entries in elfeed search."
  (interactive)
  (miniflux--ensure-elfeed)
  (unless (get-buffer (elfeed-search-buffer))
    (elfeed-search))
  (elfeed-search-set-filter (format "+%s " miniflux-sync-star-tag)))

(defun miniflux-show-sync-failed ()
  "Show entries whose local changes failed to sync to Miniflux."
  (interactive)
  (miniflux--ensure-elfeed)
  (unless (get-buffer (elfeed-search-buffer))
    (elfeed-search))
  (elfeed-search-set-filter (format "+%s " miniflux-sync-failed-tag)))

(defun miniflux-show-category (category)
  "Show Miniflux entries tagged with CATEGORY in elfeed search."
  (interactive "sMiniflux category: ")
  (miniflux--ensure-elfeed)
  (unless (get-buffer (elfeed-search-buffer))
    (elfeed-search))
  (elfeed-search-set-filter
   (format "+%s%s " miniflux-category-tag-prefix (miniflux--slugify category))))

(defun miniflux-show-feed ()
  "Show entries from the selected entry's feed in elfeed search."
  (interactive nil elfeed-search-mode)
  (miniflux--ensure-elfeed)
  (let ((id (miniflux--entry-mf-feed-id (miniflux--selected-entry))))
    (unless id
      (user-error "Selected entry has no Miniflux feed id"))
    (elfeed-search-set-filter (format "@6-months-ago =miniflux://%d " id))))

;;; ─── Tag sync hooks (elfeed → Miniflux) ───

(defun miniflux--entry-mf-ids (entries)
  "Return Miniflux numeric IDs for ENTRIES."
  (delq nil (mapcar #'miniflux--entry-mf-id entries)))

(defun miniflux--push-entries-status (entries status)
  "Push STATUS for Miniflux ENTRIES and update failure tags."
  (let ((ids (miniflux--entry-mf-ids entries)))
    (when ids
      (if (miniflux-update-entry-status ids status)
          (miniflux--clear-entries-sync-failed entries)
        (miniflux--mark-entries-sync-failed entries)))))

(defun miniflux--toggle-entries-bookmark (entries)
  "Toggle Miniflux bookmark state for ENTRIES and update failure tags."
  (dolist (entry entries)
    (let ((mf-id (miniflux--entry-mf-id entry)))
      (when mf-id
        (if (miniflux-toggle-entry-bookmark mf-id)
            (miniflux--clear-entries-sync-failed (list entry))
          (miniflux--mark-entries-sync-failed (list entry)))))))

(defun miniflux--tag-hook (entries tags)
  "Push tag additions from elfeed to Miniflux in real-time.
Called via `elfeed-tag-hook' when the user adds tags (e.g. + star).
This is the ONLY mechanism for local→server star pushes.  Sync does
NOT push — it only pulls from server."
  (condition-case err
      (progn
        (when (memq 'unread tags)
          (miniflux--push-entries-status entries "unread"))
        (when (memq miniflux-sync-star-tag tags)
          (miniflux--toggle-entries-bookmark entries)))
    (error
     (miniflux--mark-entries-sync-failed entries)
     (message "Miniflux tag-hook error: %s" (error-message-string err)))))

(defun miniflux--untag-hook (entries tags)
  "Push tag removals from elfeed to Miniflux in real-time.
Called via `elfeed-untag-hook' when the user removes tags (e.g. - star).
This is the ONLY mechanism for local→server star pushes.  Sync does
NOT push — it only pulls from server."
  (condition-case err
      (progn
        (when (memq 'unread tags)
          (miniflux--push-entries-status entries "read"))
        (when (memq miniflux-sync-star-tag tags)
          (miniflux--toggle-entries-bookmark entries)))
    (error
     (miniflux--mark-entries-sync-failed entries)
     (message "Miniflux untag-hook error: %s" (error-message-string err)))))

;;; ─── Install hooks and keybindings ───

(defsubst miniflux--tag-hook-var ()
  "Return the elfeed tag hook symbol for this elfeed version."
  (if (boundp 'elfeed-tag-hook) 'elfeed-tag-hook 'elfeed-tag-hooks))

(defsubst miniflux--untag-hook-var ()
  "Return the elfeed untag hook symbol for this elfeed version."
  (if (boundp 'elfeed-untag-hook) 'elfeed-untag-hook 'elfeed-untag-hooks))

(defun miniflux--refresh-search-maybe (_total)
  "Refresh the elfeed search buffer if it currently exists.
Intended as a `miniflux-sync' completion callback."
  (when (get-buffer (elfeed-search-buffer))
    (with-current-buffer (elfeed-search-buffer)
      (elfeed-search-update :force))))

(defun miniflux-search-refresh ()
  "Sync from Miniflux server and refresh elfeed search buffer.
Sync runs asynchronously; the search buffer is refreshed when it
finishes, so Emacs stays responsive."
  (interactive nil elfeed-search-mode)
  (miniflux-sync #'miniflux--refresh-search-maybe))

(defun miniflux--install-hooks ()
  "Install tag sync hooks and keybindings."
  (miniflux--ensure-elfeed)
  (let ((tv (miniflux--tag-hook-var))
        (utv (miniflux--untag-hook-var)))
    (unless (member #'miniflux--tag-hook (symbol-value tv))
      (add-hook tv #'miniflux--tag-hook))
    (unless (member #'miniflux--untag-hook (symbol-value utv))
      (add-hook utv #'miniflux--untag-hook))))

(defun miniflux--setup-keybindings ()
  "Set up keybindings for Miniflux integration in elfeed modes."
  (with-eval-after-load 'elfeed-search
    (define-key elfeed-search-mode-map "G" #'miniflux-search-refresh)
    (define-key elfeed-search-mode-map "M" #'miniflux-mark-current-feed-read)
    (define-key elfeed-search-mode-map "O" #'miniflux-open-entry-in-miniflux)
    (define-key elfeed-search-mode-map "R" #'miniflux-retry-sync-failed)
    (when (fboundp 'evil-define-key)
      (evil-define-key 'normal elfeed-search-mode-map
        "G" #'miniflux-search-refresh
        "M" #'miniflux-mark-current-feed-read
        "O" #'miniflux-open-entry-in-miniflux
        "R" #'miniflux-retry-sync-failed))))

(miniflux--setup-keybindings)

;;; ─── Entry point ───

(defun miniflux ()
  "Sync from Miniflux server and open elfeed search buffer.
Sync runs in the background; the search buffer is refreshed
automatically when the sync finishes."
  (interactive)
  (miniflux-sync #'miniflux--refresh-search-maybe)
  (miniflux--ensure-elfeed)
  (let ((elfeed-feeds nil))
    (elfeed-search))
  (with-current-buffer (elfeed-search-buffer)
    (elfeed-search-set-filter "+unread ")))

(provide 'miniflux)
;;; miniflux.el ends here
