# IM / XMPP features #

  * Sensitive to contacts' status; only sends notifications when you're available
  * Uses [XHTML-IM](http://xmpp.org/extensions/xep-0071.html) to include hyperlinks to host and service pages in messages.
  * Concise message rendering.
  * Summarizes Nagios conditions (e.g. 6 critical, 1 warning) in its IM status.
  * Request status details by sending the name of a host or "host/service".
  * `status` command provides on-demand status reports.
  * `check` command lets you force an active check of a host or service.
  * `ack` command lets you acknowledge a problem.
  * Tags notifications with @n references for easy acknowledgement; simply send `@5 ack` to acknowledge the problem in notification 5. (Shamelessly borrowed from the [FriendFeed](http://friendfeed.com/) IM gateway.)
  * Allows management of its IM contacts through administrative commands.

# SMTP features #

  * Supports sending notifications via SMTP. This can be done as a fallback alternative to IM; if a user is not online, they can receive notifications by email if desired.

# Nagios features #

  * Includes command plugin for sending out notifications instantly.
  * Reads Nagios configuration and state files for full reporting capabilities.
  * Supports sending [external commands](http://www.nagios.org/development/apis/externalcommands/) to Nagios.

# General #

  * Pluggable message formatting; includes email, XMPP, and XMPP+XHTML formatters.