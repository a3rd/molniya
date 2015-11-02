# Requirements #

  * A Unix/Linux system running Nagios 3.
  * An XMPP server and user account; Google Talk works.
  * An SMTP server to relay outgoing mail.
  * Ruby 1.8 with the following gems:
    * metaid
    * xmpp4r
    * sinatra
    * rack
    * mongrel

# Molniya setup #

  1. Install the required gems listed above.
  1. Copy the sample configuration in [example.yaml](http://molniya.googlecode.com/svn/trunk/example.yaml) and fill in appropriate values for the various settings. See the comments in example.yaml for guidance.
  1. Configure your Nagios IM contacts with their IM addresses (XMPP JIDs) in the selected xmpp\_field; I use `address1`.
  1. Launch the server:
```
   $ ./molniya config.yaml
```
  1. Connect to your XMPP server as the Molniya account and add your own IM account as a contact.

It should now be working; check by sending it the message 'status'. It should reply with a status report of current faults, or the message "All clear." If so, you're all set.

# Nagios notification setup #

The included `notify` utility is used as a Nagios notification command to send messages through Molniya via XMPP or SMTP. The file [notify.cfg](http://molniya.googlecode.com/svn/trunk/notify.cfg) contains the appropriate command definitions; edit the path as appropriate for your installation.

To actually use this notification method, configure Nagios contacts to use the `molniya-notify` and `molniya-host-notify` commands as
`service_notification_commands` and `host_notification_commands`. See the
comments in notify.cfg for an example and discussion.