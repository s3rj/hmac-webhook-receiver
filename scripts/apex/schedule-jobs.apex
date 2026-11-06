// Schedule the housekeeping job. Run once per org.
//   sf apex run --target-org <org> --file scripts/apex/schedule-jobs.apex
// Event purge: daily at 02:30. Deletes Processed, Ignored, and Rejected events past their source's retention.
Id purgeId = WebhookEventPurge.schedule();
System.debug(LoggingLevel.INFO, 'Scheduled "' + WebhookEventPurge.JOB_NAME + '" (' + purgeId + ').');
