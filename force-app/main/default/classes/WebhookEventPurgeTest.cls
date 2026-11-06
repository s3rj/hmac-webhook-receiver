@IsTest
private class WebhookEventPurgeTest {
    private static Webhook_Event__c event(String status, Integer daysAgo) {
        WebhookSources.sourceOverrides = new Map<String, WebhookSources.Source>{
            'demo' => new WebhookSources.Source('Demo').withRetention(30)
        };
        return new Webhook_Event__c(
            Source__c = 'Demo',
            Event_Type__c = 'ping',
            External_Event_Id__c = 'Demo:' + status + ':' + daysAgo + ':' + Crypto.getRandomInteger(),
            Status__c = status,
            Received_At__c = System.now().addDays(-daysAgo),
            Attempts__c = 0
        );
    }

    @IsTest
    static void deletesSettledEventsPastTheSourceRetention() {
        List<Webhook_Event__c> events = new List<Webhook_Event__c>{
            event('Processed', 31),
            event('Processed', 29),
            event('Ignored', 40),
            event('Rejected', 40),
            event('Failed', 100),
            event('Received', 100)
        };
        insert events;

        Test.startTest();
        Database.executeBatch(new WebhookEventPurge());
        Test.stopTest();

        Set<Id> remaining = new Map<Id, Webhook_Event__c>([SELECT Id FROM Webhook_Event__c WHERE Id IN :events]).keySet();
        Assert.isFalse(remaining.contains(events[0].Id), 'processed event older than 30 days deleted');
        Assert.isTrue(remaining.contains(events[1].Id), 'recent processed event kept');
        Assert.isFalse(remaining.contains(events[2].Id), 'old ignored event deleted');
        Assert.isFalse(remaining.contains(events[3].Id), 'old rejected delivery deleted');
        Assert.isTrue(remaining.contains(events[4].Id), 'failed event kept until someone looks');
        Assert.isTrue(remaining.contains(events[5].Id), 'received event kept for the processor');
    }

    @IsTest
    static void scheduledRunLaunchesTheBatch() {
        Webhook_Event__c old = event('Processed', 400);
        insert old;

        Test.startTest();
        new WebhookEventPurge().execute((SchedulableContext) null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Webhook_Event__c WHERE Id = :old.Id], 'purged');
    }

    @IsTest
    static void scheduleRegistersTheDailyJob() {
        Id cronId = WebhookEventPurge.schedule();

        CronTrigger cron = [SELECT CronExpression, CronJobDetail.Name FROM CronTrigger WHERE Id = :cronId];
        Assert.areEqual('0 30 2 * * ?', cron.CronExpression, 'daily at 02:30');
        Assert.areEqual('Webhook event purge', cron.CronJobDetail.Name, 'job name');
    }

    @IsTest
    static void expiryFollowsTheSourceRetention() {
        Datetime now = System.now();
        Assert.isTrue(WebhookEventPurge.isExpired(event('Processed', 31), now), 'past the source retention');
        Assert.isFalse(WebhookEventPurge.isExpired(event('Processed', 29), now), 'within it');
        Assert.isFalse(WebhookEventPurge.isExpired(event('Failed', 400), now), 'failed events never expire');
        Assert.areEqual(30, WebhookSources.shortestRetentionDays(), 'horizon is the shortest retention');

        WebhookSources.sourceOverrides.put('fast', new WebhookSources.Source('Fast').withRetention(7));
        Assert.areEqual(7, WebhookSources.shortestRetentionDays(), 'horizon follows the shortest source');
        Assert.areEqual(7, WebhookSources.retentionDaysFor('FAST'), 'per-source lookup, case-insensitive');
        Assert.areEqual(30, WebhookSources.retentionDaysFor('nope'), 'unknown source gets the default');
    }
}
