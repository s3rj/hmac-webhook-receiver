/**
 * Test handler: records what it was given and can be told to throw.
 */
@IsTest
public class RecordingWebhookHandler implements WebhookHandler {
    public static List<Id> handled = new List<Id>();
    public static List<String> types = new List<String>();
    public static Boolean lastPayloadWasNull = false;
    public static Boolean explode = false;

    public void handle(Webhook_Event__c event, Map<String, Object> payload) {
        handled.add(event.Id);
        types.add(event.Event_Type__c);
        lastPayloadWasNull = payload == null;
        if (explode) {
            throw new WebhookDispatcher.HandlerException('boom');
        }
    }
}
