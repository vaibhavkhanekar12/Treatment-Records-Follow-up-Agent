// Run as the automation user that holds the Follow_Up_Automation permission set.
// Schedules the nightly Treatment & Records Follow-up evaluation (default 02:00 org time).
System.debug(FollowUpNightlyScheduler.schedule(null));

// Optional: run one evaluation immediately.
// System.debug(FollowUpNightlyScheduler.run());
