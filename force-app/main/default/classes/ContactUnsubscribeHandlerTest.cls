@IsTest
private class ContactUnsubscribeHandlerTest {
    @IsTest
    static void optsOutEveryContactWithTheEmail() {
        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'One', Email = 'gone@example.com'),
            new Contact(LastName = 'Two', Email = 'gone@example.com', HasOptedOutOfEmail = true),
            new Contact(LastName = 'Three', Email = 'stays@example.com')
        };
        insert contacts;
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped('{"id":"evt_1","type":"contact.unsubscribed","email":"gone@example.com"}');

        new ContactUnsubscribeHandler().handle(new Webhook_Event__c(), payload);

        Map<Id, Contact> after = new Map<Id, Contact>([SELECT HasOptedOutOfEmail FROM Contact WHERE Id IN :contacts]);
        Assert.isTrue(after.get(contacts[0].Id).HasOptedOutOfEmail, 'opted out');
        Assert.isTrue(after.get(contacts[1].Id).HasOptedOutOfEmail, 'already opted out stays opted out');
        Assert.isFalse(after.get(contacts[2].Id).HasOptedOutOfEmail, 'other address untouched');
    }

    @IsTest
    static void payloadWithoutAnEmailIsAHandlerError() {
        try {
            new ContactUnsubscribeHandler().handle(new Webhook_Event__c(), new Map<String, Object>{ 'id' => 'evt_2' });
            Assert.fail('expected HandlerException');
        } catch (WebhookDispatcher.HandlerException e) {
            Assert.isTrue(e.getMessage().contains('no email'), 'reason: ' + e.getMessage());
        }
    }
}
