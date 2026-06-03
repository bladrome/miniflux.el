;;; miniflux.el --- Miniflux RSS client using elfeed UI -*- lexical-binding: t; -*-

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
;;
;; In elfeed-search-mode:
;;   G  — sync from Miniflux server and refresh
;;   g  — refresh from local database (revert)
;;   r  — sync from Miniflux server and refresh (evil/Doom)
;;   u  — mark as unread (syncs to Miniflux)
;;   r  — mark as read (syncs to Miniflux, non-evil)
;;   +  — add tag (e.g. + star to sync star to Miniflux)
;;   -  — remove tag

;;; Code:

(require 'cl-lib)
(require 'gv)
(require 'parse-time)
(require 'url)

(eval-when-compile
  (unless (require 'elfeed nil t)
    (package-initialize)
    (require 'elfeed)))

(unless (require 'elfeed nil t)
  (package-initialize)
  (require 'elfeed))

(defun miniflux--ensure-elfeed ()
  "Ensure elfeed is loaded and available."
  (unless (featurep 'elfeed)
    (package-initialize)
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

(gv-define-setter elfeed-entry-tags (val entry)
  `(miniflux--set-entry-tags ,entry ,val))

(gv-define-setter elfeed-entry-title (val entry)
  `(miniflux--set-entry-title ,entry ,val))

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

(defvar miniflux--sync-in-progress nil
  "Non-nil when a sync is running.")

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

(defun miniflux--request (method path &optional data params)
  "Make a synchronous HTTP request to the Miniflux API.
METHOD: :GET :PUT :POST :DELETE.
PATH: API path (without /v1).
DATA: alist for JSON body.
PARAMS: alist for query string.
Returns parsed JSON on success, t for 204, nil on error."
  (let ((url-request-method (format "%s" (substring (symbol-name method) 1)))
        (url-request-extra-headers (miniflux--auth-headers))
        (url-request-data nil)
        (url (miniflux--api-url path)))
    (when (member method '(:POST :PUT))
      (push '("Content-Type" . "application/json") url-request-extra-headers)
      (when data
        (setq url-request-data (encode-coding-string (json-encode data) 'utf-8))))
    (when params
      (setq url (concat url "?" (mapconcat
                                 (lambda (p)
                                   (format "%s=%s"
                                           (url-hexify-string (car p))
                                           (url-hexify-string (cdr p))))
                                 params "&"))))
    (condition-case err
        (with-current-buffer (url-retrieve-synchronously url)
          (prog1
              (let* ((body-start (miniflux--http-body))
                     (status (miniflux--http-status)))
                (cond
                 ((null body-start) nil)
                 ((and status (>= status 400))
                  (message "Miniflux HTTP %d" status)
                  nil)
                 ((= status 204) t)
                 (t
                  (let ((body (decode-coding-string
                               (string-to-unibyte
                                (buffer-substring-no-properties body-start (point-max)))
                               'utf-8)))
                     (json-read-from-string body)))))
            (kill-buffer (current-buffer))))
      (error
       (message "Miniflux error: %S" (error-message-string err))
       nil))))

;;; ─── API: Feeds ───

(defun miniflux-get-feeds ()
  "Return list of all feeds."
  (miniflux--request :GET "/feeds"))

(defun miniflux-get-feed (id)
  "Return details for feed ID."
  (miniflux--request :GET (format "/feeds/%d" id)))

(defun miniflux-get-feed-entries (id &rest filters)
  "Return entries for feed ID with FILTERS plist."
  (let (params)
    (while filters
      (let ((key (pop filters)) (val (pop filters)))
        (push (cons (substring (symbol-name key) 1) (format "%s" val)) params)))
    (miniflux--request :GET (format "/feeds/%d/entries" id) nil params)))

(defun miniflux-get-entries (&rest filters)
  "Return entries with FILTERS plist."
  (let (params)
    (while filters
      (let ((key (pop filters)) (val (pop filters)))
        (push (cons (substring (symbol-name key) 1) (format "%s" val)) params)))
    (miniflux--request :GET "/entries" nil params)))

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

(defun miniflux--entry-category-tag (entry)
  "Return the Miniflux category title for ENTRY as a symbol, or nil."
  (let* ((feed-data (assoc-default 'feed entry))
         (category (assoc-default 'category feed-data))
         (cat-title (assoc-default 'title category)))
    (when (and cat-title (not (string-empty-p cat-title)))
      (intern (replace-regexp-in-string "[ \t]+" "-" (downcase cat-title))))))

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
     :meta `(,@(when (and author (not (string-empty-p author)))
                 (list :authors (list (list :name author))))))))

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
             (elfeed-feed--create :id feed-id-str :url feed-id-str :title feed-title)
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

(defun miniflux--reconcile-all-stars (api-starred-ids)
  "Reconcile star tags for ALL local miniflux entries against the API.
API-STARRED-IDS is a hash table keyed by entry-id (cons) for entries
that are starred on the server.  Iterates over every miniflux entry in
`elfeed-db-entries' and forces the local star tag to match the server.
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
            ;; Local has star, API doesn't → remove star
            ((and has-star (not should-star))
             (setf (elfeed-entry-tags entry)
                   (delq miniflux-sync-star-tag tags))
             (setq changed (1+ changed)))
            ;; API has star, local doesn't → add star
            ((and should-star (not has-star))
             (push miniflux-sync-star-tag tags)
             (setf (elfeed-entry-tags entry) tags)
             (setq changed (1+ changed)))))))
     elfeed-db-entries)
    changed))

(defun miniflux--reconcile-entry-tags (api-table)
  "Reconcile unread and category tags for entries present in API-TABLE.
API-TABLE maps entry-id (cons) to raw API entry alist.  For each entry
that exists locally, force unread and category tags to match the API
state.  Star reconciliation is handled separately by
`miniflux--reconcile-all-stars' which covers ALL local entries.

Uses direct (setf elfeed-entry-tags) → no elfeed hooks are triggered."
  (maphash
   (lambda (id api-entry)
     (let* ((api-unread (equal (assoc-default 'status api-entry) "unread"))
            (api-cat (miniflux--entry-category-tag api-entry))
            (e (gethash id elfeed-db-entries)))
       (when e
         ;; Fix titles with newlines
         (let ((title (elfeed-entry-title e)))
           (when (string-match-p "[\n\r]" title)
             (setf (elfeed-entry-title e)
                   (replace-regexp-in-string "[\n\r]+" " " title))))
         ;; Reconcile unread and category tags to match API state
         (let ((tags (elfeed-entry-tags e)))
           ;; Unread tag
           (when (and api-unread (not (memq 'unread tags)))
             (push 'unread tags))
           (when (and (not api-unread) (memq 'unread tags))
             (setq tags (delq 'unread tags)))
           ;; Category tag
           (when (and api-cat (not (memq api-cat tags)))
             (push api-cat tags))
           (setf (elfeed-entry-tags e) tags)))))
   api-table))

(defun miniflux-sync ()
  "Sync entries from Miniflux server into elfeed's database.

Sync is PULL-ONLY — the server is the single source of truth.
Local→server pushes happen in real-time via elfeed tag hooks
(see `miniflux--tag-hook' / `miniflux--untag-hook').

Flow:
  1. Fetch starred, unread, and recent entries from the API.
  2. Add/update them in elfeed DB (elfeed-db-add preserves local tags
     for existing entries; reconciliation fixes them in step 4).
  3. Build api-starred-ids: the complete set of starred entry IDs.
  4. Star reconciliation: iterate over ALL local miniflux entries
     and force star tags to match api-starred-ids.  This covers entries
     that exist locally but weren't in any API batch (read+unstarred+old).
  5. Unread/category reconciliation: for entries in api-table, sync
     unread and category tags.
  6. Save."
  (interactive)
  (miniflux--check-auth)
  (miniflux--ensure-elfeed)
  (miniflux--install-hooks)
  (when miniflux--sync-in-progress
    (user-error "Sync already in progress"))
  (let ((miniflux--sync-in-progress t))
    (message "Miniflux: syncing...")
    (let ((api-table (make-hash-table :test 'equal))
          (api-starred-ids (make-hash-table :test 'equal))
          (total-entries 0))
      ;; Phase 1: Fetch from API and add to elfeed DB.
      ;; Starred batch first → builds the authoritative starred ID set.
      (dolist (batch (list (list :limit miniflux-sync-limit :starred "1")
                           (list :limit miniflux-sync-limit :status "unread")
                           (list :limit miniflux-sync-limit :order "published_at")))
        (let ((raw (miniflux--fetch-and-store batch)))
          (when raw
            (setq total-entries (+ total-entries (length raw)))
            (dolist (e (append raw nil))
              (let ((id (cons 'miniflux (format "%d" (assoc-default 'id e)))))
                (puthash id e api-table)
                (when (eq t (assoc-default 'starred e))
                  (puthash id t api-starred-ids)))))))
      ;; Phase 2: Reconcile star tags for ALL local miniflux entries.
      ;; This is the critical step — it iterates elfeed-db-entries (not
      ;; just api-table) so even entries not in any API batch get their
      ;; star corrected.  api-starred-ids is the authoritative reference.
      (let ((star-changes (miniflux--reconcile-all-stars api-starred-ids)))
        (when (> star-changes 0)
          (message "Miniflux: reconciled %d star tag(s)" star-changes)))
      ;; Phase 3: Reconcile unread/category tags for API-fetched entries.
      (miniflux--reconcile-entry-tags api-table)
      (elfeed-db-save)
      (if (> total-entries 0)
          (message "Miniflux: synced %d entries" total-entries)
        (message "Miniflux: no entries found (check server/credentials)")))))

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

;;; ─── Tag sync hooks (elfeed → Miniflux) ───

(defun miniflux--tag-hook (entries tags)
  "Push tag additions from elfeed to Miniflux in real-time.
Called via `elfeed-tag-hook' when the user adds tags (e.g. + star).
This is the ONLY mechanism for local→server star pushes.  Sync does
NOT push — it only pulls from server."
  (when (memq 'unread tags)
    (let ((ids (delq nil (mapcar #'miniflux--entry-mf-id entries))))
      (when ids
        (miniflux-update-entry-status ids "unread"))))
  (when (memq miniflux-sync-star-tag tags)
    (dolist (entry entries)
      (let ((mf-id (miniflux--entry-mf-id entry)))
        (when mf-id
          (miniflux-toggle-entry-bookmark mf-id))))))

(defun miniflux--untag-hook (entries tags)
  "Push tag removals from elfeed to Miniflux in real-time.
Called via `elfeed-untag-hook' when the user removes tags (e.g. - star).
This is the ONLY mechanism for local→server star pushes.  Sync does
NOT push — it only pulls from server."
  (when (memq 'unread tags)
    (let ((ids (delq nil (mapcar #'miniflux--entry-mf-id entries))))
      (when ids
        (miniflux-update-entry-status ids "read"))))
  (when (memq miniflux-sync-star-tag tags)
    (dolist (entry entries)
      (let ((mf-id (miniflux--entry-mf-id entry)))
        (when mf-id
          (miniflux-toggle-entry-bookmark mf-id))))))

;;; ─── Install hooks and keybindings ───

(defsubst miniflux--tag-hook-var ()
  "Return the elfeed tag hook symbol for this elfeed version."
  (if (boundp 'elfeed-tag-hook) 'elfeed-tag-hook 'elfeed-tag-hooks))

(defsubst miniflux--untag-hook-var ()
  "Return the elfeed untag hook symbol for this elfeed version."
  (if (boundp 'elfeed-untag-hook) 'elfeed-untag-hook 'elfeed-untag-hooks))

(defun miniflux-search-refresh ()
  "Sync from Miniflux server and refresh elfeed search buffer."
  (interactive nil elfeed-search-mode)
  (miniflux-sync)
  (elfeed-search-update :force))

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
    (when (fboundp 'evil-define-key)
      (evil-define-key 'normal elfeed-search-mode-map
        "G" #'miniflux-search-refresh
        "r" #'miniflux-search-refresh))))

(miniflux--setup-keybindings)

;;; ─── Entry point ───

(defun miniflux ()
  "Sync from Miniflux server and open elfeed search buffer."
  (interactive)
  (miniflux--check-auth)
  (miniflux--install-hooks)
  (miniflux-sync)
  (miniflux--ensure-elfeed)
  (let ((elfeed-feeds nil))
    (elfeed-search))
  (with-current-buffer (elfeed-search-buffer)
    (elfeed-search-set-filter "+unread ")))

(provide 'miniflux)
;;; miniflux.el ends here
