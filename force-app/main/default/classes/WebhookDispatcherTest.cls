@IsTest
private class WebhookDispatcherTest {
    private static void handlers(Map<String, WebhookDispatcher.HandlerConfig> configs) {
        WebhookDispatcher.handlerOverrides = configs;
    }

    private static WebhookDispatcher.HandlerConfig recording(Boolean async) {
        return new WebhookDispatcher.HandlerConfig('RecordingWebhookHandler', async);
    }

    private static Webhook_Event__c event(String type, String payload) {
        Webhook_Event__c event = new Webhook_Event__c(
            Source__c = 'Demo',
            Event_Type__c = type,
            External_Event_Id__c = 'Demo:' + type + ':' + Crypto.getRandomInteger(),
            Status__c = 'Received',
            Received_At__c = System.now(),
            Payload__c = payload,
            Attempts__c = 0
        );
        insert event;
        return event;
    }

    private static Webhook_Event__c reload(Id eventId) {
        return [SELECT Status__c, Handler_Class__c, Processed_Async__c, Attempts__c, Processed_At__c, Error_Message__c FROM Webhook_Event__c WHERE Id = :eventId];
    }

    @IsTest
    static void syncHandlerRunsInsideTheRequest() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|ping' => recording(false) });
        Webhook_Event__c event = event('ping', '{"type":"ping"}');

        String status = WebhookDispatcher.dispatch(event);

        Assert.areEqual('Processed', status, 'processed now');
        Webhook_Event__c after = reload(event.Id);
        Assert.areEqual('Processed', after.Status__c, 'status recorded');
        Assert.areEqual('RecordingWebhookHandler', after.Handler_Class__c, 'handler recorded');
        Assert.isFalse(after.Processed_Async__c, 'ran synchronously');
        Assert.areEqual(1, after.Attempts__c.intValue(), 'one attempt');
        Assert.isNotNull(after.Processed_At__c, 'processed time');
        Assert.areEqual(new List<Id>{ event.Id }, RecordingWebhookHandler.handled, 'handler saw the event');
        Assert.isFalse(RecordingWebhookHandler.lastPayloadWasNull, 'JSON payload parsed for the handler');
    }

    @IsTest
    static void asyncHandlerIsQueuedAndRunsLater() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|ping' => recording(true) });
        Webhook_Event__c event = event('ping', '{"type":"ping"}');

        Test.startTest();
        String status = WebhookDispatcher.dispatch(event);
        Assert.areEqual('Received', status, 'still Received when the request returns');
        Assert.areEqual(new List<Id>{ event.Id }, WebhookDispatcher.lastQueued, 'queued');
        Assert.isTrue(RecordingWebhookHandler.handled.isEmpty(), 'not run inside the request');
        Test.stopTest();

        Webhook_Event__c after = reload(event.Id);
        Assert.areEqual('Processed', after.Status__c, 'processed by the queueable');
        Assert.isTrue(after.Processed_Async__c, 'marked async');
        Assert.areEqual(new List<Id>{ event.Id }, RecordingWebhookHandler.handled, 'handler ran');
    }

    @IsTest
    static void eventsWithoutAHandlerAreIgnored() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|ping' => recording(false) });
        Webhook_Event__c event = event('something.else', '{}');

        Assert.areEqual('Ignored', WebhookDispatcher.dispatch(event), 'ignored');
        Assert.areEqual('Ignored', reload(event.Id).Status__c, 'status recorded');
        Assert.isTrue(RecordingWebhookHandler.handled.isEmpty(), 'no handler ran');
    }

    @IsTest
    static void wildcardHandlerCatchesEveryTypeFromASource() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|*' => recording(false) });
        Webhook_Event__c event = event('anything.at.all', '{}');

        Assert.areEqual('Processed', WebhookDispatcher.dispatch(event), 'wildcard handled it');
    }

    @IsTest
    static void exactTypeWinsOverTheWildcard() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{
            'demo|*' => new WebhookDispatcher.HandlerConfig('Fallback', true),
            'demo|ping' => new WebhookDispatcher.HandlerConfig('Exact', false)
        });

        Assert.areEqual('Exact', WebhookDispatcher.findHandler('Demo', 'PING').handlerClass, 'exact match, case-insensitive');
        Assert.areEqual('Fallback', WebhookDispatcher.findHandler('demo', 'other').handlerClass, 'wildcard for the rest');
        Assert.isNull(WebhookDispatcher.findHandler('github', 'push'), 'nothing for another source');
    }

    @IsTest
    static void shippedHandlerMetadataIsRead() {
        WebhookDispatcher.HandlerConfig config = WebhookDispatcher.findHandler('Demo', 'contact.unsubscribed');

        Assert.isNotNull(config, 'shipped Demo handler found');
        Assert.areEqual('ContactUnsubscribeHandler', config.handlerClass, 'handler class');
        Assert.isTrue(config.runAsync, 'async by default');
    }

    @IsTest
    static void handlerExceptionsMarkTheEventFailedWithTheReason() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|ping' => recording(false) });
        RecordingWebhookHandler.explode = true;
        Webhook_Event__c event = event('ping', '{}');

        Assert.areEqual('Failed', WebhookDispatcher.dispatch(event), 'failed');
        Webhook_Event__c after = reload(event.Id);
        Assert.areEqual('Failed', after.Status__c, 'status recorded');
        Assert.isTrue(after.Error_Message__c.contains('boom'), 'reason recorded: ' + after.Error_Message__c);
        Assert.areEqual(1, after.Attempts__c.intValue(), 'attempt counted');
    }

    @IsTest
    static void missingOrWrongHandlerClassesFailCleanly() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{
            'demo|missing' => new WebhookDispatcher.HandlerConfig('NoSuchHandlerClass', false),
            'demo|wrong' => new WebhookDispatcher.HandlerConfig('JsonPath', false)
        });
        Webhook_Event__c missing = event('missing', '{}');
        Webhook_Event__c wrong = event('wrong', '{}');

        WebhookDispatcher.dispatch(missing);
        WebhookDispatcher.dispatch(wrong);

        Assert.isTrue(reload(missing.Id).Error_Message__c.contains('not found'), 'missing class reported');
        Assert.isTrue(reload(wrong.Id).Error_Message__c.contains('does not implement'), 'wrong class reported');
    }

    @IsTest
    static void reprocessRerunsFailedEventsAndSkipsProcessedOnes() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|ping' => recording(false) });
        RecordingWebhookHandler.explode = true;
        Webhook_Event__c failed = event('ping', '{}');
        WebhookDispatcher.dispatch(failed);
        Assert.areEqual('Failed', reload(failed.Id).Status__c, 'failed first');
        Webhook_Event__c done = event('ping', '{}');
        RecordingWebhookHandler.explode = false;
        WebhookDispatcher.dispatch(done);

        Map<Id, String> outcomes = WebhookDispatcher.reprocess(new List<Id>{ failed.Id, done.Id });

        Assert.areEqual('Processed', outcomes.get(failed.Id), 'failed event re-run');
        Assert.isFalse(outcomes.containsKey(done.Id), 'processed event skipped');
        Assert.areEqual(2, reload(failed.Id).Attempts__c.intValue(), 'attempts accumulate');
        Assert.isNull(reload(failed.Id).Error_Message__c, 'error cleared');
    }

    @IsTest
    static void nonJsonPayloadsReachTheHandlerAsNull() {
        handlers(new Map<String, WebhookDispatcher.HandlerConfig>{ 'demo|ping' => recording(false) });
        Webhook_Event__c event = event('ping', 'this is not json');

        WebhookDispatcher.dispatch(event);

        Assert.isTrue(RecordingWebhookHandler.lastPayloadWasNull, 'handler told there was no JSON object');
    }

    @IsTest
    static void processorRecoveryMarksStrandedEventsFailed() {
        Webhook_Event__c stranded = event('ping', '{}');

        new WebhookProcessor.Recovery(new List<Id>{ stranded.Id }).execute(new AbortedContext());

        Webhook_Event__c after = reload(stranded.Id);
        Assert.areEqual('Failed', after.Status__c, 'stranded event failed');
        Assert.isTrue(after.Error_Message__c.contains('Apex CPU time limit exceeded'), 'reason recorded');
        Assert.areEqual(1, after.Attempts__c.intValue(), 'attempt counted');

        new WebhookProcessor.Recovery(new List<Id>{ stranded.Id }).execute(new SuccessContext());
        Assert.areEqual('Failed', reload(stranded.Id).Status__c, 'success path leaves events alone');
    }

    private class AbortedContext implements FinalizerContext {
        public Id getAsyncApexJobId() {
            return null;
        }
        public String getRequestId() {
            return 'test';
        }
        public ParentJobResult getResult() {
            return ParentJobResult.UNHANDLED_EXCEPTION;
        }
        public Exception getException() {
            return new WebhookDispatcher.HandlerException('Apex CPU time limit exceeded');
        }
    }

    private class SuccessContext implements FinalizerContext {
        public Id getAsyncApexJobId() {
            return null;
        }
        public String getRequestId() {
            return 'test';
        }
        public ParentJobResult getResult() {
            return ParentJobResult.SUCCESS;
        }
        public Exception getException() {
            return null;
        }
    }
}
