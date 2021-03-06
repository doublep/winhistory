;;; winhistory.el --- Track and redisplay recent buffers per window  -*- lexical-binding: t -*-

;; Copyright (C) 2015 Paul Pogonyshev

;; Author:     Paul Pogonyshev <pogonyshev@gmail.com>
;; Maintainer: Paul Pogonyshev <pogonyshev@gmail.com>
;; Version:    0.1
;; Keywords:   convenience
;; Homepage:   https://github.com/doublep/winhistory
;; Package-Requires: ((emacs "24.1") (dash "2.11"))

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see http://www.gnu.org/licenses.


;;; Commentary:

;; A global minor mode to switch buffers respecting window context.
;; In addition to the global buffer list, this mode tracks buffers
;; that have been recently visible in a window and prefers switching
;; to those instead.
;;
;; For each window the mode keeps track of all buffers it has ever
;; shown (and that hasn't been killed).  When a buffer is shown in the
;; window outside or in the end of switching process, it is moved to
;; the beginning of this list.
;;
;; During switching the mode builds list of all buffers: first buffers
;; in the window history, then all other buffers.  Buffers matching
;; conditions in `winhistory-ignored-buffers' are removed from this
;; list (normally these are things like minibuffers etc.).  Next, all
;; "uninteresting" buffers (see `winhistory-uninteresting-buffers')
;; are moved to the end of the list.
;;
;; During switching you can use next/previous commands (by default
;; F8/F7), any characters to extend buffer name filter, and backspace
;; to delete the last character in this filter.  Any other command
;; immediately finalizes switching at the buffer you are currently in
;; and is additionally passed to the buffer to execute its command.
;; For example, F8 C-s switches to the next buffer in window history
;; and immediately starts incremental search in it.


;;; Code:

(eval-when-compile (require 'dash))



;;; Customization.

;; We will "rebuild" it from the custom variables.
(defvar winhistory-mode-map
  (make-sparse-keymap)
  "Keymap for Winhistory mode.")

(defvar winhistory-active-switch-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-g")         'winhistory-cancel-switch)
    map)
  "Keymap active during a switch process.")

(defvar winhistory-active-filter-switch-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<right>")     'winhistory-next)
    (define-key map (kbd "<left>")      'winhistory-previous)
    (define-key map (kbd "DEL")         'winhistory-delete-last-filter-char)
    (define-key map (kbd "<backspace>") 'winhistory-delete-last-filter-char)
    (define-key map (kbd "RET")         'winhistory-finalize-active-buffer-switch)
    (define-key map (kbd "<return>")    'winhistory-finalize-active-buffer-switch)
    map)
  "Keymap active during a switch process that involved filtering.
These bindings are not active when you first initiate a switch,
but are activated if you type any filter characters.")

(defun winhistory--rebuild-keymap (variable value)
  (when (and (boundp variable) (symbol-value variable))
    (define-key winhistory-mode-map (symbol-value variable) nil))
  (set-default variable value)
  (define-key winhistory-mode-map (symbol-value variable)
    (pcase variable
      (`winhistory-next-buffer-keybinding     'winhistory-next)
      (`winhistory-previous-buffer-keybinding 'winhistory-previous)
      (`winhistory-filter-keybinding          'winhistory-filter)
      (`winhistory-bury-buffer-keybinding     'winhistory-bury-buffer))))


(defgroup winhistory nil
  "Winhistory global minor mode."
  :group 'convenience)


(defcustom winhistory-next-buffer-keybinding
  (kbd "<M-S-right>")
  "Keybinding to switch to the next buffer.
You can also tweak keymap `winhistory-mode-map' directly.

The default keybinding conflicts with command `left-word' when
`shift-select-mode' is active.  You may want to change this
keybinding if you rely on that."
  :type  'key-sequence
  :set   'winhistory--rebuild-keymap
  :group 'winhistory)

(defcustom winhistory-previous-buffer-keybinding
  (kbd "<M-S-left>")
  "Keybinding to switch to the previous buffer.
You can also tweak keymap `winhistory-mode-map' directly.

The default keybinding conflicts with command `left-word' when
`shift-select-mode' is active.  You may want to change this
keybinding if you rely on that."
  :type  'key-sequence
  :set   'winhistory--rebuild-keymap
  :group 'winhistory)

(defcustom winhistory-filter-keybinding
  (kbd "<M-S-up>")
  "Enable filter during the current switch.
If no buffer switch is currently in progress, a new one is
started."
  :type  'key-sequence
  :set   'winhistory--rebuild-keymap
  :group 'winhistory)

(defcustom winhistory-bury-buffer-keybinding
  (kbd "<M-S-down>")
  "Bury currently selected buffer.
If no buffer switch is currently in progress the command
additionally starts one."
  :type  'key-sequence
  :set   'winhistory--rebuild-keymap
  :group 'winhistory)

(defcustom winhistory-buffer-matcher
  'winhistory-name-substring-buffer-matcher
  "Matcher that checks whether a buffer matches entered filter.

There are three standard matcher functions, as well as
possibility to define your own, see below.

Exact buffer name substring

    Matching buffer name must include the filter as exact
    substring.  E.g. filter \"ead\" matches a buffer named
    \"readme.txt\", but \"ead.txt\" does not.  This is the
    default.

Buffer name word part subsequence

    Matching buffer name must include all word parts from the
    filter, possibly with intervening characters.  For example,
    filter \"ead.txt\" matches a buffer named \"readme.txt\"
    (even though there is no \"me\" in the filter), but
    \"eadtxt\" does not.

Buffer name character subsequence

    Matching buffer name must include all characters from the
    filter, possibly with additional intervening characters.
    E.g. \"eadtxt\" matches a buffer named \"readme.txt\".

You can also define your own matcher, even not limited to looking
at buffer names.  A matcher must be a function that accepts two
arguments: FILTER (string, may be nil if there is no filter) and
STD-CASE-FOLD-SEARCH (t or nil).  The latter is computed from
`winhistory-case-fold-filter', with `no-uppercase' already
processed as described.  The function must return a list of
exactly three elements:

    (FILTER-ARG MATCHER-FN CASE-FOLD-SEARCH)

FILTER-ARG

    Preprocessed filter, normally a regexp for buffer name (but
    see the next argument).

MATCHER-FN

    If nil, FILTER-ARG is used as a regexp and matched against
    buffer name.  Otherwise, this must be a function that accepts
    FILTER-ARG (as above) and BUFFER and returns non-nil if the
    buffer matches the filter.  Note that it receives the full
    buffer structure, not just its name.

CASE-FOLD-SEARCH

    Value to bind `case-fold-search' to.  Normally you should
    just return STD-CASE-FOLD-SEARCH untouched here, but there
    are no restrictions."
  :type  '(choice (const :tag "Exact buffer name substring"
                         winhistory-name-substring-buffer-matcher)
                  (const :tag "Buffer name word part subsequence"
                         winhistory-name-word-part-subsequence-buffer-matcher)
                  (const :tag "Buffer name character subsequence"
                         winhistory-name-char-subsequence-buffer-matcher)
                  (symbol :tag "Custom")))


(defcustom winhistory-ignored-buffers '("\\` ")
  "List of regexps or functions matching buffers to ignore completely.

Regexps are applied to buffer names.  If any matches, the buffer
is ignored and doesn't appear in the list of options at all.
Functions are applied to buffer itself.  If any returns a non-nil
value, buffer is similarly ignored.

See also `winhistory-uninteresting-buffers'."
  :type  '(repeat (choice regexp function))
  :group 'winhistory)

(defcustom winhistory-uninteresting-buffers nil
  "List of regexps or functions matching buffers to list last.

Regexps are applied to buffer names.  If any matches, the buffer
is pushed to the back of list of options.  Functions are applied
to buffer itself.  If any returns a non-nil value, buffer is
treated similarly.

Unlike ignored buffer, \"uninteresting\" buffers still appear in
the list of options, just after all normal (\"interesting\")
buffers.  It is thus still possible to switch to them using
Winhistory commands.  Normally you would make buffers that have
special commands to activate \"uninteresting\" so that switching
to other buffers is easier.

See also `winhistory-ignored-buffers'."
  :type  '(repeat (choice regexp function))
  :group 'winhistory)


(defcustom winhistory-case-fold-filter 'no-uppercase
  "Whether to use buffer name filters case-sensitively.
t means to ignore case, nil to always match case-sensitively.
Value `no-uppercase' means use case-insensitive matching unless
the filter contains an uppercase letter."
  :type  '(choice (const :tag "Yes" t)
                  (const :tag "No"  nil)
                  (const :tag "Yes, unless there is an uppercase letter" no-uppercase)))


(defface winhistory-selected-buffer
  '((t :inherit bold))
  "Face to highlight the selected buffer."
  :group 'winhistory)

(defface winhistory-filter
  '((t :inherit font-lock-string-face))
  "Face to highlight buffer switch filter."
  :group 'winhistory)



;;; Internal variables.

(defvar winhistory--buffer-histories nil)

(defvar winhistory--active-switch nil
  "Details of current buffer switching process.
When set, this is an plist with the following properties:
':window', ':all-buffers', ':buffers', ':index', ':from', ':to'',
':filter', ':filter-activated', ':index-stack'.")

(defvar winhistory--after-filter ": ")
(defvar winhistory--left-arrow   "...")
(defvar winhistory--right-arrow  "...")
(defvar winhistory--separator    " | ")



;;; The mode.

;;;###autoload
(define-minor-mode winhistory-mode
  "Toggle Winhistory tracking and keybindings.
With a prefix argument ARG, enable Winhistory if ARG is positive,
and disable it otherwise.  If called from Lisp, enable the mode
if ARG is omitted or nil."
  :global t
  :keymap winhistory-mode-map
  :group  'winhistory
  (if winhistory-mode
      (winhistory--set-up)
    (winhistory--shut-down)))



;;; Commands.

(defun winhistory-next ()
  "Switch to the next buffer candidate."
  (interactive)
  (winhistory--maybe-start-switch)
  (winhistory--continue-switch +1))

(defun winhistory-previous ()
  "Switch to the previous buffer candidate.
As an exception, when this command is used to start switching
process, it does not switch the buffer.  This is because the
previous buffer at that point is the least important candidate.
Instead you are just presented with switching options."
  (interactive)
  ;; If this starts switching process, we intentionally don't change
  ;; the selected buffer.
  (winhistory--continue-switch (unless (winhistory--maybe-start-switch) -1)))

(defun winhistory-filter ()
  (interactive)
  (winhistory--maybe-start-switch)
  (winhistory--set-active-switch :filter-activated t)
  (winhistory--continue-switch))

(defun winhistory-bury-buffer ()
  (interactive)
  ;; FIXME
  )

(defun winhistory-extend-filter ()
  "Add a character to the buffer switching filter.
This command is supposed to be \"bound\" to self-inserting keys
only."
  (interactive)
  (when (and winhistory--active-switch (characterp last-command-event))
    (-let (((&plist :index index :filter filter :index-stack index-stack) winhistory--active-switch))
      (winhistory--set-active-switch :filter-activated t
                                     :filter           (concat filter (this-command-keys))
                                     :index-stack      (cons index index-stack))
      (winhistory--refilter-and-continue))))

(defun winhistory-delete-last-filter-char ()
  "Delete the last character of buffer switching filter.
If the filter is already empty, silently do nothing."
  (interactive)
  (when winhistory--active-switch
    (-let (((&plist :filter filter :index-stack index-stack) winhistory--active-switch))
      (winhistory--set-active-switch :filter-activated t
                                     :filter           (when (> (length filter) 1) (substring filter 0 -1))
                                     :index-stack      (cdr index-stack))
      (winhistory--refilter-and-continue (car index-stack)))))

(defun winhistory-finalize-active-buffer-switch ()
  "Finalize buffer switching process.
This moves the current buffer to the beginnig of list (both
result of `buffer-list' and window-specific history tracked by
this mode).

Silently do nothing if there is no active switching process."
  (interactive)
  (remove-hook 'pre-command-hook 'winhistory--before-command)
  (when winhistory--active-switch
    (with-selected-window (plist-get winhistory--active-switch :window)
      (setq winhistory--active-switch nil)
      (switch-to-buffer (current-buffer) nil t)
      (winhistory--track-window-history))))

(defun winhistory-cancel-switch ()
  (interactive)
  (when winhistory--active-switch
    (-let (((&plist :window window :all-buffers all-buffers) winhistory--active-switch))
      (with-selected-window window
        (switch-to-buffer (aref all-buffers 0) t t)
        (winhistory-finalize-active-buffer-switch)))))



;;; Buffer matchers.

(defun winhistory-name-substring-buffer-matcher (filter std-case-fold-search)
  (list (when filter (regexp-quote filter))
        nil
        std-case-fold-search))

(defun winhistory-name-word-part-subsequence-buffer-matcher (filter std-case-fold-search)
  (list (when filter
          (substring (replace-regexp-in-string "\\w+\\|." (lambda (part) (concat ".*" (regexp-quote part))) filter t t) 2))
        nil
        std-case-fold-search))

(defun winhistory-name-char-subsequence-buffer-matcher (filter std-case-fold-search)
  (list (when filter (mapconcat (lambda (char) (regexp-quote (char-to-string char))) filter ".*"))
        nil
        std-case-fold-search))



;;; Internal functions.

(defun winhistory--set-up ()
  (add-hook 'buffer-list-update-hook 'winhistory--track-window-history))

(defun winhistory--shut-down ()
  (remove-hook 'buffer-list-update-hook 'winhistory--track-window-history)
  (setq winhistory--buffer-histories nil)
  (winhistory-finalize-active-buffer-switch))

(defun winhistory--track-window-history ()
  (unless winhistory--active-switch
    (unless winhistory--buffer-histories
      (setq winhistory--buffer-histories (make-hash-table :test 'eq :weakness 'key)))
    (let* ((all-buffers   (buffer-list))
           (buried-buffer (nth (1- (length all-buffers)) all-buffers)))
      (walk-windows (lambda (window)
                      (let* ((top-buffer (window-buffer window))
                             refreshed-stack
                             had-buried-buffer)
                        (dolist (stacked-buffer (gethash window winhistory--buffer-histories))
                          (unless (or (not (buffer-live-p stacked-buffer)) (eq stacked-buffer top-buffer))
                            (if (eq stacked-buffer buried-buffer)
                                (setq had-buried-buffer t)
                              (push stacked-buffer refreshed-stack))))
                        (when had-buried-buffer
                          (setq refreshed-stack (cons buried-buffer refreshed-stack)))
                        (puthash window (cons top-buffer (nreverse refreshed-stack))
                                 winhistory--buffer-histories)))))))

(defun winhistory--set-active-switch (&rest properties)
  (while properties
    (setq winhistory--active-switch (plist-put winhistory--active-switch (car properties) (cadr properties))
          properties                (cddr properties))))

(defun winhistory--maybe-start-switch ()
  (unless winhistory--active-switch
    (when (window-minibuffer-p)
      (user-error "Cannot switch buffers in minibuffer window"))
    (when (eq (window-dedicated-p) t)
      (user-error "Cannot switch buffers in a dedicated window"))
    (let ((seen-buffers (make-hash-table :test 'eq))
          interesting-buffers
          uninteresting-buffers)
      (when winhistory--buffer-histories
        (dolist (buffer (gethash (selected-window) winhistory--buffer-histories))
          (when (and (buffer-live-p buffer) (not (winhistory--ignored-p buffer)))
            (push buffer (if (winhistory--uninteresting-p buffer) uninteresting-buffers interesting-buffers))
            (puthash buffer t seen-buffers))))
      (dolist (buffer (buffer-list))
        (unless (or (gethash buffer seen-buffers) (winhistory--ignored-p buffer))
          (push buffer (if (winhistory--uninteresting-p buffer) uninteresting-buffers interesting-buffers))))
      (let ((all-buffers (vconcat (nreverse interesting-buffers) (nreverse uninteresting-buffers))))
        (winhistory--set-active-switch :window      (selected-window)
                                       :all-buffers all-buffers
                                       :buffers     all-buffers
                                       :index       0)
        (add-hook 'pre-command-hook 'winhistory--before-command)))
    t))

(defun winhistory--continue-switch (&optional change)
  (-let (((&plist :window window :buffers buffers :index index) winhistory--active-switch))
    (with-selected-window window
      (when (> (length buffers) 0)
        (when change
          (winhistory--set-active-switch :index       (setq index (mod (+ index change) (length buffers)))
                                         :index-stack nil))
        (switch-to-buffer (aref buffers index) t t))
      (let ((message-log-max nil))
        (message "%s" (winhistory--format-switch-options (window-body-width (minibuffer-window))))))))

(defun winhistory--refilter-and-continue (&optional new-index)
  (-let* (((&plist :buffers buffers :all-buffers all-buffers :filter filter :index index) winhistory--active-switch)
          ((filter matcher case-fold-search)
           (funcall winhistory-buffer-matcher
                    filter (if (and filter (eq winhistory-case-fold-filter 'no-uppercase))
                               (not (let ((case-fold-search nil)) (string-match "[[:upper:]]" filter)))
                             winhistory-case-fold-filter)))
          (seen-current     nil)
          (buffers          nil))
    (dotimes (k (length all-buffers))
      (let ((buffer (aref all-buffers k)))
        (when (eq buffer (current-buffer))
          (setq seen-current t))
        (when (if matcher
                  (funcall matcher filter buffer)
                (or (null filter) (string-match filter (buffer-name buffer))))
          (when (and (null new-index) seen-current)
            (setq new-index (length buffers)))
          (push buffer buffers))))
    (winhistory--set-active-switch :buffers (vconcat (nreverse buffers))
                                   :index   new-index
                                   :from    nil)
    (winhistory--continue-switch)))
    

(defun winhistory--ignored-p (buffer)
  (winhistory--buffer-matches buffer winhistory-ignored-buffers))

(defun winhistory--uninteresting-p (buffer)
  (winhistory--buffer-matches buffer winhistory-uninteresting-buffers))

(defun winhistory--buffer-matches (buffer options)
  (--any (if (stringp it)
             (string-match it (buffer-name buffer))
           (funcall it buffer))
         options))

(defun winhistory--format-switch-options (length-limit)
  (-let* (((&plist :buffers buffers :index index :from from :to to :filter filter :filter-activated filter-activated)
           winhistory--active-switch)
          (last (1- (length buffers))))
    (concat (when filter-activated
              (concat (propertize (or filter "") 'face 'winhistory-filter) winhistory--after-filter))
            (if (< last 0)
                "[no match]"
              (when (or (null from)
                        (< index from)
                        (> index to)
                        (and (or (= index from) (= index to)) (> (- to from) 5)))
                ;; Recompute from/to.
                (setq from index
                      to   index)
                (let ((total-length (+ (if filter (+ (length filter) (length winhistory--after-filter)) 0)
                                       (if (> from 0) (length winhistory--left-arrow) 0)
                                       (length (buffer-name (aref buffers index)))
                                       (if (< to last) (length winhistory--right-arrow) 0))))
                  (while (and (< total-length length-limit)
                              (or (> from 0) (< to last)))
                    (let ((prepend (or (= to last)
                                       (and (> from 0) (> (- to index) (* 3 (- index from)))))))
                      (setq total-length (+ total-length
                                            (length winhistory--separator)
                                            (length (buffer-name (aref buffers (if prepend (1- from) (1+ to)))))
                                            (if (and prepend (= from 1)) (- (length winhistory--left-arrow)) 0)
                                            (if (and (not prepend) (= (1+ to) last)) (- (length winhistory--right-arrow)) 0)))
                      (when (<= total-length length-limit)
                        (if prepend
                            (setq from (1- from))
                          (setq to (1+ to)))))))
                (winhistory--set-active-switch :from from
                                               :to   to))
              (let (strings)
                (when (> from 0)
                  (push winhistory--left-arrow strings))
                (let ((k from))
                  (while (<= k to)
                    (when (> k from)
                      (push winhistory--separator strings))
                    (let ((buffer (buffer-name (aref buffers k))))
                      (push (if (= k index)
                                (propertize buffer 'face 'winhistory-selected-buffer)
                              buffer)
                            strings))
                    (setq k (1+ k))))
                (when (< to last)
                  (push winhistory--right-arrow strings))
                (apply 'concat (nreverse strings)))))))

(defun winhistory--do-lookup-key (map keys)
  (let ((result (lookup-key map keys)))
    (unless (integerp result)
      result)))

(defun winhistory--before-command ()
  (if winhistory--active-switch
      (unless (memq this-command '(winhistory-next winhistory-previous))
        (let* ((keys            (this-command-keys))
               (filtering       (plist-get winhistory--active-switch :filter-activated))
               (special-command (or (winhistory--do-lookup-key winhistory-active-switch-map keys)
                                    (and filtering (winhistory--do-lookup-key winhistory-active-filter-switch-map keys)))))
          (if special-command
              (setq this-command special-command)
            (if (and filtering (memq (winhistory--do-lookup-key global-map keys) '(self-insert-command nil)))
                (setq this-command 'winhistory-extend-filter)
              (winhistory-finalize-active-buffer-switch)))))
    (winhistory-finalize-active-buffer-switch)))


(provide 'winhistory)

;;; winhistory.el ends here
