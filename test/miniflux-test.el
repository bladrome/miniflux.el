;;; miniflux-test.el --- Tests for miniflux.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'miniflux)

(ert-deftest miniflux-api-url-adds-v1 ()
  (let ((miniflux-server "https://example.com"))
    (should (equal (miniflux--api-url "/entries")
                   "https://example.com/v1/entries"))))

(ert-deftest miniflux-api-url-keeps-existing-v1 ()
  (let ((miniflux-server "https://example.com/v1/"))
    (should (equal (miniflux--api-url "/entries")
                   "https://example.com/v1/entries"))))

(ert-deftest miniflux-auth-headers-prefers-token ()
  (let ((miniflux-token "token")
        (miniflux-username "user")
        (miniflux-password "pass"))
    (should (equal (miniflux--auth-headers)
                   '(("X-Auth-Token" . "token"))))))

(ert-deftest miniflux-entry-category-tag-normalizes-title ()
  (let ((entry '((feed . ((category . ((title . "Tech News"))))))))
    (should (eq (miniflux--entry-category-tag entry) 'tech-news))))

(ert-deftest miniflux-reconcile-all-stars-uses-custom-star-tag ()
  (let* ((miniflux-sync-star-tag 'favorite)
         (elfeed-db-entries (make-hash-table :test 'equal))
         (api-starred-ids (make-hash-table :test 'equal))
         (id (cons 'miniflux "1"))
         (entry (elfeed-entry--create :id id :title "t" :tags '(unread))))
    (puthash id entry elfeed-db-entries)
    (puthash id t api-starred-ids)
    (should (= (miniflux--reconcile-all-stars api-starred-ids) 1))
    (should (memq 'favorite (elfeed-entry-tags entry)))
    (should-not (memq 'star (elfeed-entry-tags entry)))))

(ert-deftest miniflux-reconcile-unread-incomplete-batch-does-not-remove ()
  (let* ((elfeed-db-entries (make-hash-table :test 'equal))
         (api-unread-ids (make-hash-table :test 'equal))
         (id (cons 'miniflux "1"))
         (entry (elfeed-entry--create :id id :title "t" :tags '(unread))))
    (puthash id entry elfeed-db-entries)
    (should (= (miniflux--reconcile-all-unread api-unread-ids nil) 0))
    (should (memq 'unread (elfeed-entry-tags entry)))))

(ert-deftest miniflux-reconcile-entry-tags-preserves-user-tags ()
  (let* ((elfeed-db-entries (make-hash-table :test 'equal))
         (api-table (make-hash-table :test 'equal))
         (id (cons 'miniflux "1"))
         (entry (elfeed-entry--create :id id
                                      :title "multi\nline"
                                      :tags '(unread favorite custom))))
    (puthash id entry elfeed-db-entries)
    (puthash id '((feed . ((category . ((title . "Tech News")))))) api-table)
    (miniflux--reconcile-entry-tags api-table)
    (should (equal (elfeed-entry-title entry) "multi line"))
    (should (memq 'unread (elfeed-entry-tags entry)))
    (should (memq 'favorite (elfeed-entry-tags entry)))
    (should (memq 'custom (elfeed-entry-tags entry)))
    (should (memq 'tech-news (elfeed-entry-tags entry)))))

;;; miniflux-test.el ends here
