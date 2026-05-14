import { nanoid } from 'nanoid';

export type EventEnvelope<TPayload = Record<string, unknown>> = {
  event_id: string;
  type: string;
  created_at: string;
  user_id?: string;
  device_id?: string;
  workspace_id?: string;
  session_id?: string;
  turn_id?: string;
  payload: TPayload;
};

export function createEvent<TPayload>(
  type: string,
  payload: TPayload,
  options: Omit<EventEnvelope<TPayload>, 'event_id' | 'type' | 'created_at' | 'payload'> = {},
): EventEnvelope<TPayload> {
  return {
    event_id: `evt_${nanoid(16)}`,
    type,
    created_at: new Date().toISOString(),
    ...options,
    payload,
  };
}

export function parseEvent(raw: string): EventEnvelope | null {
  try {
    const value = JSON.parse(raw) as EventEnvelope;
    if (!value || typeof value.type !== 'string' || typeof value.event_id !== 'string') {
      return null;
    }
    return value;
  } catch {
    return null;
  }
}
