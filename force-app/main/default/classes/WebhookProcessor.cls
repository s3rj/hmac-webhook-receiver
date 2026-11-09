/**
 * Runs handlers outside the HTTP request so the sender gets its 200 in milliseconds and a slow or failing
 * handler cannot make the sender retry (and redeliver) the event. A Finalizer marks the events Failed and
 * raises an alert if the job itself dies from a limit exception, so nothing stays "Received" forever.
 */
public without sharing class WebhookProcessor implements Queueable {
    private final List<Id> eventIds;

    public WebhookProcessor(List<Id> eventIds) {
        this.eventIds = eventIds;
    }

    public void execute(QueueableContext context) {
        System.attachFinalizer(new Recovery(eventIds));
        for (Webhook_Event__c event : [
            SELECT Id, Source__c, Event_Type__c, External_Event_Id__c, Payload__c, Status__c, Attempts__c
            FROM Webhook_Event__c
            WHERE Id IN :eventIds AND Status__c = :WebhookEvents.STATUS_RECEIVED
        ]) {
            WebhookDispatcher.HandlerConfig config = WebhookDispatcher.findHandler(event.Source__c, event.Event_Type__c);
            if (config == null) {
                WebhookEvents.markIgnored(event);
            } else {
                WebhookDispatcher.process(event, config, true);
            }
        }
    }

    /** Without sharing, like the job itself: a stranded event must be marked whatever the running user can see. */
    public without sharing class Recovery implements Finalizer {
        private final List<Id> eventIds;

        public Recovery(List<Id> eventIds) {
            this.eventIds = eventIds;
        }

        public void execute(FinalizerContext context) {
            if (context.getResult() == ParentJobResult.SUCCESS) {
                return;
            }
            String reason = 'Processor aborted: ' + context.getException().getMessage();
            List<Webhook_Event__c> stranded = [
                SELECT Id, Source__c, Event_Type__c, External_Event_Id__c, Attempts__c
                FROM Webhook_Event__c
                WHERE Id IN :eventIds AND Status__c = :WebhookEvents.STATUS_RECEIVED
            ];
            for (Webhook_Event__c event : stranded) {
                event.Status__c = WebhookEvents.STATUS_FAILED;
                event.Attempts__c = (event.Attempts__c == null ? 0 : event.Attempts__c) + 1;
                event.Error_Message__c = WebhookEvents.clip(reason, WebhookEvents.ERROR_MAX);
            }
            update stranded;
            WebhookEvents.alertAll(WebhookEvents.ALERT_PROCESSOR_ABORTED, stranded, reason);
        }
    }
}
