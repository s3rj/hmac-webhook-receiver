/**
 * Finds the handler for an event (Webhook_Handler__mdt by source and event type, "*" as the fallback) and runs
 * it now or in a queueable. Failed events can be re-run after the handler is fixed.
 */
public without sharing class WebhookDispatcher {
    public class HandlerConfig {
        public String handlerClass { get; private set; }
        public Boolean runAsync { get; private set; }

        public HandlerConfig(String handlerClass, Boolean runAsync) {
            this.handlerClass = handlerClass;
            this.runAsync = runAsync == null ? true : runAsync;
        }
    }

    public class HandlerException extends Exception {
    }

    /** Test overrides keyed by "source|eventType" (lower-cased). */
    @TestVisible
    private static Map<String, HandlerConfig> handlerOverrides;
    @TestVisible
    private static List<Id> lastQueued = new List<Id>();

    /** Routes a freshly stored event. Returns the status it ended up in (Processed, Failed, Ignored, or Received when queued). */
    public static String dispatch(Webhook_Event__c event) {
        HandlerConfig config = findHandler(event.Source__c, event.Event_Type__c);
        if (config == null) {
            WebhookEvents.markIgnored(event);
            return WebhookEvents.STATUS_IGNORED;
        }
        if (config.runAsync) {
            lastQueued = new List<Id>{ event.Id };
            System.enqueueJob(new WebhookProcessor(lastQueued));
            return WebhookEvents.STATUS_RECEIVED;
        }
        return process(event, config, false);
    }

    /** Runs the handler for one stored event and records the outcome. */
    public static String process(Webhook_Event__c event, HandlerConfig config, Boolean async) {
        try {
            WebhookHandler handler = instantiate(config.handlerClass);
            handler.handle(event, parse(event.Payload__c));
            WebhookEvents.markProcessed(event, config.handlerClass, async);
            return WebhookEvents.STATUS_PROCESSED;
        } catch (Exception e) {
            WebhookEvents.markFailed(event, config.handlerClass, async, e);
            return WebhookEvents.STATUS_FAILED;
        }
    }

    /** Re-runs the handler for Failed (or Ignored, once a handler exists) events, synchronously. */
    public static Map<Id, String> reprocess(List<Id> eventIds) {
        Map<Id, String> outcomes = new Map<Id, String>();
        for (Webhook_Event__c event : [
            SELECT Id, Source__c, Event_Type__c, External_Event_Id__c, Payload__c, Status__c, Attempts__c
            FROM Webhook_Event__c
            WHERE Id IN :eventIds AND Status__c IN (:WebhookEvents.STATUS_FAILED, :WebhookEvents.STATUS_IGNORED, :WebhookEvents.STATUS_RECEIVED)
        ]) {
            HandlerConfig config = findHandler(event.Source__c, event.Event_Type__c);
            if (config == null) {
                WebhookEvents.markIgnored(event);
                outcomes.put(event.Id, WebhookEvents.STATUS_IGNORED);
                continue;
            }
            outcomes.put(event.Id, process(event, config, false));
        }
        return outcomes;
    }

    /** The configured handler for a source and event type: exact type first, then the source's "*" fallback. */
    public static HandlerConfig findHandler(String source, String eventType) {
        Map<String, HandlerConfig> handlers = handlerOverrides != null ? handlerOverrides : loadHandlers();
        String sourceKey = source == null ? '' : source.toLowerCase();
        HandlerConfig exact = eventType == null ? null : handlers.get(sourceKey + '|' + eventType.toLowerCase());
        return exact != null ? exact : handlers.get(sourceKey + '|*');
    }

    private static Map<String, HandlerConfig> cache;

    private static Map<String, HandlerConfig> loadHandlers() {
        if (cache == null) {
            cache = new Map<String, HandlerConfig>();
            for (Webhook_Handler__mdt record : [
                SELECT Source__c, Event_Type__c, Handler_Class__c, Run_Async__c
                FROM Webhook_Handler__mdt
                WHERE Active__c = true
                LIMIT 1000
            ]) {
                cache.put(record.Source__c.toLowerCase() + '|' + record.Event_Type__c.toLowerCase(), new HandlerConfig(record.Handler_Class__c, record.Run_Async__c));
            }
        }
        return cache;
    }

    private static WebhookHandler instantiate(String className) {
        Type handlerType = Type.forName(className);
        if (handlerType == null) {
            throw new HandlerException('Handler class not found: ' + className);
        }
        Object instance = handlerType.newInstance();
        if (!(instance instanceof WebhookHandler)) {
            throw new HandlerException(className + ' does not implement WebhookHandler');
        }
        return (WebhookHandler) instance;
    }

    private static Map<String, Object> parse(String payload) {
        if (String.isBlank(payload)) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(payload);
            return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
        } catch (JSONException e) {
            return null;
        }
    }
}
