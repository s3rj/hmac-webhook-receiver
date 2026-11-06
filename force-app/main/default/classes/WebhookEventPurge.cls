/**
 * Housekeeping: deletes settled events (Processed, Ignored, Rejected) once they are older than their source's
 * retention, so a busy sender's payloads do not eat storage forever. Failed events are kept until someone
 * reprocesses or deletes them; Received events are the processor's and the finalizer's business.
 */
public without sharing class WebhookEventPurge implements Schedulable, Database.Batchable<SObject> {
    public static final String JOB_NAME = 'Webhook event purge';
    /** 02:30 every day, org time. */
    public static final String CRON_DAILY = '0 30 2 * * ?';
    public static final Integer BATCH_SIZE = 2000;
    public static final Set<String> SETTLED_STATUSES = new Set<String>{
        WebhookEvents.STATUS_PROCESSED, WebhookEvents.STATUS_IGNORED, WebhookEvents.STATUS_REJECTED
    };

    /** Schedules the daily run. Run once per org. */
    public static Id schedule() {
        return System.schedule(JOB_NAME, CRON_DAILY, new WebhookEventPurge());
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(this, BATCH_SIZE);
    }

    /** Everything settled before the shortest retention; execute() applies each source's own. */
    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime horizon = System.now().addDays(-WebhookSources.shortestRetentionDays());
        return Database.getQueryLocator([
            SELECT Id, Source__c, Status__c, Received_At__c
            FROM Webhook_Event__c
            WHERE Status__c IN :SETTLED_STATUSES AND Received_At__c < :horizon
        ]);
    }

    public void execute(Database.BatchableContext context, List<Webhook_Event__c> scope) {
        List<Webhook_Event__c> expired = new List<Webhook_Event__c>();
        Datetime now = System.now();
        for (Webhook_Event__c event : scope) {
            if (isExpired(event, now)) {
                expired.add(event);
            }
        }
        Database.delete(expired, false); // an event someone has locked should not stop the rest
    }

    public void finish(Database.BatchableContext context) {
        return; // nothing to summarize
    }

    public static Boolean isExpired(Webhook_Event__c event, Datetime now) {
        if (event.Received_At__c == null || !SETTLED_STATUSES.contains(event.Status__c)) {
            return false;
        }
        return event.Received_At__c < now.addDays(-WebhookSources.retentionDaysFor(event.Source__c));
    }
}
