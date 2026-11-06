/**
 * What a webhook handler implements. Configured per source and event type in Webhook_Handler__mdt and created
 * with Type.forName(), so it needs a public no-argument constructor.
 *
 * The handler runs after the delivery has been verified, stored, and deduplicated. It may do DML. If it throws,
 * the event is marked Failed with the message, and it can be re-run with WebhookDispatcher.reprocess().
 */
public interface WebhookHandler {
    /**
     * @param event   the stored Webhook_Event__c (Id, Source__c, Event_Type__c, External_Event_Id__c, Payload__c ...)
     * @param payload the JSON body parsed with JSON.deserializeUntyped(), or null when the body was not a JSON object
     */
    void handle(Webhook_Event__c event, Map<String, Object> payload);
}
