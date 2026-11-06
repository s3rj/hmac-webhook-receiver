/**
 * Sample handler: a marketing tool reports that an address unsubscribed, so every Contact with that email
 * is opted out. Payload: { "id": "...", "type": "contact.unsubscribed", "email": "someone@example.com" }.
 */
public with sharing class ContactUnsubscribeHandler implements WebhookHandler {
    public void handle(Webhook_Event__c event, Map<String, Object> payload) {
        String email = JsonPath.getString(payload, 'email');
        if (String.isBlank(email)) {
            throw new WebhookDispatcher.HandlerException('payload has no email');
        }
        List<Contact> contacts = [SELECT Id, HasOptedOutOfEmail FROM Contact WHERE Email = :email AND HasOptedOutOfEmail = false LIMIT 200];
        for (Contact contact : contacts) {
            contact.HasOptedOutOfEmail = true;
        }
        update contacts;
    }
}
