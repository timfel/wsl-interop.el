;;; wsl-interop.el --- Run Windows shell commands from WSL Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tim Felgentreff

;; Author: Tim Felgentreff
;; URL: https://github.com/timfel/agent-shell-utils
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Subprocess helpers for running Windows executables either directly or from WSL.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup wsl-interop nil
  "Run Windows PowerShell and CMD commands via WSL interop."
  :group 'processes)

(defcustom wsl-interop-powershell-arguments
  '("-NoLogo" "-NoProfile" "-NonInteractive" "-ExecutionPolicy" "Bypass")
  "Arguments passed to `powershell.exe' before `-Command'."
  :type '(repeat string))

(defcustom wsl-interop-cmd-arguments
  '("/d" "/s")
  "Arguments passed to `cmd.exe' before `/c'."
  :type '(repeat string))

(defvar wsl-interop--executable-cache (make-hash-table :test #'equal)
  "Cache of resolved Windows executable paths.")

(defun wsl-interop--read-file (file)
  "Return FILE contents as a string, or nil when FILE is unreadable."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

;;;###autoload
(defun wsl-p ()
  "Return non-nil when Emacs is running inside WSL2."
  (and (eq system-type 'gnu/linux)
       (let ((osrelease (wsl-interop--read-file "/proc/sys/kernel/osrelease"))
             (version (wsl-interop--read-file "/proc/version"))
             (interop (getenv "WSL_INTEROP")))
         (or (and osrelease (string-match-p "WSL2\|microsoft-standard-WSL2" osrelease))
             (and interop
                  osrelease
                  (string-match-p "microsoft" osrelease)
                  (not (string-match-p "Microsoft$" (string-trim osrelease))))
             (and interop
                  version
                  (string-match-p "WSL2" version))))))

(defun wsl-interop--call-with-output (&rest args)
  "Run process ARGS and return trimmed stdout.
ARGS should start with a program name followed by its arguments.
Signal an error when the command exits unsuccessfully."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)
          (coding-system-for-write 'utf-8-unix))
      (let ((exit-code (apply #'process-file (car args) nil (current-buffer) nil
                              (cdr args))))
        (unless (eq exit-code 0)
          (error "%s failed with exit code %s: %s"
                 (car args)
                 exit-code
                 (string-trim (buffer-string))))
        (string-trim-right (buffer-string))))))

(defun wsl-interop--windows-path-directories ()
  "Return the Windows PATH entries reported by `wslvar PATH'."
  (let ((path (wsl-interop--call-with-output "wslvar" "PATH")))
    (split-string path ";" t)))

(defun wsl-interop--windows-path-to-linux (path)
  "Convert Windows PATH to a Linux path using `wslpath -u'."
  (wsl-interop--call-with-output "wslpath" "-u" path))

(defun wsl-interop--find-executable-via-wslvar (executable)
  "Resolve EXECUTABLE via `wslvar PATH' and `wslpath -u'."
  (cl-loop for windows-dir in (wsl-interop--windows-path-directories)
           for linux-dir = (condition-case nil
                               (wsl-interop--windows-path-to-linux windows-dir)
                             (error nil))
           when linux-dir
           for expanded = (expand-file-name executable linux-dir)
           when (file-exists-p expanded)
           return expanded))

(defun wsl-interop--find-windows-executable (executable &optional fallback)
  "Return a Linux path for Windows EXECUTABLE.
Prefer `executable-find'.  When that fails, look for EXECUTABLE on the
Windows PATH reported by `wslvar PATH'.  FALLBACK, when non-nil, is an
additional executable name to try with `executable-find'."
  (or (gethash executable wsl-interop--executable-cache)
      (let ((resolved
             (or (executable-find executable)
                 (and fallback (executable-find fallback))
                 (wsl-interop--find-executable-via-wslvar executable))))
        (unless resolved
          (user-error "Could not find %s via PATH or WSL interop helpers"
                      executable))
        (puthash executable resolved wsl-interop--executable-cache)
        resolved)))

(defun wsl-interop--shell-command (program args)
  "Build a shell command string for PROGRAM and ARGS.
Each argument is quoted with `shell-quote-argument'."
  (mapconcat #'shell-quote-argument (cons program args) " "))

(defun wsl-interop--powershell-command-line (script)
  "Build a shell command line that runs PowerShell SCRIPT."
  (wsl-interop--shell-command
   (wsl-interop--find-windows-executable "powershell.exe" "powershell")
   (append wsl-interop-powershell-arguments (list "-Command" script))))

(defun wsl-interop--cmd-command-line (script)
  "Build a shell command line that runs CMD SCRIPT."
  (wsl-interop--shell-command
   (wsl-interop--find-windows-executable "cmd.exe" "cmd")
   (append wsl-interop-cmd-arguments (list "/c" script))))

(defun wsl-interop--async-command (command output-buffer error-buffer)
  "Run COMMAND asynchronously via `async-shell-command'."
  (async-shell-command command output-buffer error-buffer))

(defun wsl-interop--start-process (name buffer command)
  "Start COMMAND asynchronously via `start-process-shell-command'."
  (start-process-shell-command name buffer command))

;;;###autoload
(defun wsl-powershell-start-process (name buffer script)
  "Start Windows PowerShell SCRIPT asynchronously via WSL interop.
NAME and BUFFER are passed to `start-process-shell-command'."
  (wsl-interop--start-process
   name
   buffer
   (wsl-interop--powershell-command-line script)))

;;;###autoload
(defun wsl-cmd-start-process (name buffer script)
  "Start Windows CMD SCRIPT asynchronously via WSL interop.
NAME and BUFFER are passed to `start-process-shell-command'."
  (wsl-interop--start-process
   name
   buffer
   (wsl-interop--cmd-command-line script)))

;;;###autoload
(defun wsl-powershell-async-command (script &optional output-buffer error-buffer)
  "Run Windows PowerShell SCRIPT asynchronously via WSL interop.
Like `async-shell-command', send output to OUTPUT-BUFFER and errors to
ERROR-BUFFER."
  (interactive
   (list (read-shell-command "WSL async PowerShell script: ")
         async-shell-command-buffer
         shell-command-default-error-buffer))
  (wsl-interop--async-command
   (wsl-interop--powershell-command-line script)
   output-buffer
   error-buffer))

;;;###autoload
(defun wsl-cmd-async-command (script &optional output-buffer error-buffer)
  "Run Windows CMD SCRIPT asynchronously via WSL interop.
Like `async-shell-command', send output to OUTPUT-BUFFER and errors to
ERROR-BUFFER."
  (interactive
   (list (read-shell-command "WSL async CMD script: ")
         async-shell-command-buffer
         shell-command-default-error-buffer))
  (wsl-interop--async-command
   (wsl-interop--cmd-command-line script)
   output-buffer
   error-buffer))

;;;###autoload
(defun wsl-powershell-command (script &optional output-buffer error-buffer)
  "Run Windows PowerShell SCRIPT via WSL interop.
Like `shell-command', send output to OUTPUT-BUFFER and errors to
ERROR-BUFFER."
  (interactive
   (list (read-shell-command "WSL PowerShell script: ")
         current-prefix-arg
         shell-command-default-error-buffer))
  (shell-command
   (wsl-interop--powershell-command-line script)
   output-buffer
   error-buffer))

;;;###autoload
(defun wsl-cmd-command (script &optional output-buffer error-buffer)
  "Run Windows CMD SCRIPT via WSL interop.
Like `shell-command', send output to OUTPUT-BUFFER and errors to
ERROR-BUFFER."
  (interactive
   (list (read-shell-command "WSL CMD script: ")
         current-prefix-arg
         shell-command-default-error-buffer))
  (shell-command
   (wsl-interop--cmd-command-line script)
   output-buffer
   error-buffer))

;;;###autoload
(defun wsl-powershell-command-to-string (script)
  "Run Windows PowerShell SCRIPT via WSL interop and return its output."
  (shell-command-to-string (wsl-interop--powershell-command-line script)))

;;;###autoload
(defun wsl-cmd-command-to-string (script)
  "Run Windows CMD SCRIPT via WSL interop and return its output."
  (shell-command-to-string (wsl-interop--cmd-command-line script)))

(provide 'wsl-interop)
;;; wsl-interop.el ends here
