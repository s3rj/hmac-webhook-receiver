/**
 * Persistence for Webhook_Event__c: store with deduplication, and status transitions.
 */
public without sharing class WebhookEvents {
    public static final String STATUS_RECEIVED = 'Received';
    public static final String STATUS_PROCESSED = 'Processed';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_IGNORED = 'Ignored';
    public static final String STATUS_REJECTED = 'Rejected';

    public static final Integer PAYLOAD_MAX = 131072;
    public static final Integer ERROR_MAX = 32768;

    public class StoreResult {
        public Webhook_Event__c event { get; private set; }
        public Boolean duplicate { get; private set; }

        public StoreResult(Webhook_Event__c event, Boolean duplicate) {
            this.event = event;
            this.duplicate = duplicate;
        }
    }

    /**
     * Inserts the event. A unique-key collision on External Event Id means the sender redelivered something
     * already accepted: the existing record is returned and marked as a duplicate.
     */
    public static StoreResult store(Webhook_Event__c event) {
        Database.SaveResult result = Database.insert(event, false);
        if (result.isSuccess()) {
            return new StoreResult(event, false);
        }
        for (Database.Error error : result.getErrors()) {
            if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                List<Webhook_Event__c> existing = [
                    SELECT Id, Status__c, External_Event_Id__c
                    FROM Webhook_Event__c
                    WHERE External_Event_Id__c = :event.External_Event_Id__c
                    LIMIT 1
                ];
                if (!existing.isEmpty()) {
                    return new StoreResult(existing[0], true);
                }
            }
        }
        throw new DmlException('Could not store webhook event: ' + result.getErrors()[0].getMessage());
    }

    /** Records a delivery that failed verification: no payload, so a forged body is never persisted. */
    public static Webhook_Event__c rejected(String sourceName, String reason, Map<String, String> headers) {
        Webhook_Event__c event = new Webhook_Event__c(
            Source__c = clip(sourceName, 80),
            Status__c = STATUS_REJECTED,
            Received_At__c = System.now(),
            Headers__c = clip(JSON.serializePretty(headers), ERROR_MAX),
            Error_Message__c = clip(reason, ERROR_MAX)
        );
        insert event;
        return event;
    }

    public static void markProcessed(Webhook_Event__c event, String handlerClass, Boolean async) {
        event.Status__c = STATUS_PROCESSED;
        event.Handler_Class__c = handlerClass;
        event.Processed_Async__c = async;
        event.Processed_At__c = System.now();
        event.Attempts__c = (event.Attempts__c == null ? 0 : event.Attempts__c) + 1;
        event.Error_Message__c = null;
        update event;
    }

    public static void markFailed(Webhook_Event__c event, String handlerClass, Boolean async, Exception error) {
        event.Status__c = STATUS_FAILED;
        event.Handler_Class__c = handlerClass;
        event.Processed_Async__c = async;
        event.Attempts__c = (event.Attempts__c == null ? 0 : event.Attempts__c) + 1;
        event.Error_Message__c = clip(error.getTypeName() + ': ' + error.getMessage() + '\n' + error.getStackTraceString(), ERROR_MAX);
        update event;
    }

    public static void markIgnored(Webhook_Event__c event) {
        event.Status__c = STATUS_IGNORED;
        event.Processed_At__c = System.now();
        update event;
    }

    public static String clip(String value, Integer max) {
        return value == null ? null : value.abbreviate(max);
    }
}
