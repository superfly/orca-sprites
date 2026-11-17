// The Sprites panel: every Sprite this computer created for Orca, whether it is awake or asleep,
// and the workspace it was made for, with its URL and a checkpoint button. The worker does the
// work (src/protocol.ts).
import {
  atom,
  Badge,
  Button,
  Callout,
  EmptyState,
  IconButton,
  List,
  ListItem,
  plugin,
  read,
  RelativeTime,
  Row,
  set,
  shell,
  Spinner,
  Stack,
  Text,
  update,
  type PanelContext
} from 'orca'
import type { SpriteRow } from './protocol'

/** null until the first answer; stays null while the first load fails, so the panel never
 *  says "No Sprites yet" when it simply could not ask. */
const sprites = atom<SpriteRow[] | null>(null)
const error = atom<string | null>(null)
const loading = atom(false)
const busy = atom<Record<string, string>>({})
/** The checkpoint run each Sprite's spinner waits for, so another run's result never clears it,
 *  and when it started, so a list answered before it began cannot clear it either. */
const waiting: Record<string, number> = {}
const startedAt: Record<string, number> = {}
let clock = 0
const notice = atom<{ tone: 'success' | 'danger' | 'neutral'; title: string; text: string } | null>(null)

// Only the newest refresh may update the list, so a slow one can never bring back a row that a
// newer one (after Forget, say) dropped.
let latest = 0
export async function refresh(): Promise<void> {
  const mine = ++latest
  const sentAt = ++clock
  set(loading, true)
  try {
    const result = await plugin.request('sprites.list', {}, { timeoutMs: 60000 })
    if (mine !== latest) return
    set(sprites, result.sprites)
    set(error, result.error)
    // Clear only spinners started before this list was asked for: a later one is still live.
    const running = new Set(result.checkpointing ?? [])
    const stale = (name: string) => !running.has(name) && (startedAt[name] ?? 0) < sentAt
    for (const name of Object.keys(waiting)) if (stale(name)) delete waiting[name]
    update(busy, (b) =>
      Object.fromEntries(Object.entries(b).filter(([name, what]) => what !== 'Checkpointing' || !stale(name)))
    )
  } catch (e) {
    if (mine === latest) set(error, (e as Error).message)
  } finally {
    if (mine === latest) set(loading, false)
  }
}

const setBusy = (name: string, what: string | null) =>
  update(busy, ({ [name]: _, ...rest }) => (what ? { ...rest, [name]: what } : rest))

async function checkpoint(name: string): Promise<void> {
  startedAt[name] = ++clock
  setBusy(name, 'Checkpointing')
  set(notice, null)
  try {
    const { started, run } = await plugin.request('sprites.checkpoint', { name })
    if (started && run !== null) waiting[name] = run
    if (!started) setBusy(name, null)
    if (!started) set(notice, { tone: 'neutral', title: 'Already running', text: `A checkpoint of ${name} is already running.` })
  } catch (e) {
    setBusy(name, null)
    set(notice, { tone: 'danger', title: 'Checkpoint failed', text: `${name}: ${(e as Error).message}` })
  }
}

async function forget(name: string): Promise<void> {
  setBusy(name, 'Forgetting')
  try {
    await plugin.request('sprites.forget', { name })
    await refresh()
  } catch (e) {
    set(notice, { tone: 'danger', title: 'Could not forget', text: `${name}: ${(e as Error).message}` })
  } finally {
    setBusy(name, null)
  }
}

const tone = (status: string) =>
  status === 'running' ? 'success' : status === 'gone' ? 'danger' : status === 'unknown' ? 'warning' : 'neutral'
const label = (status: string) =>
  status === 'running' ? 'awake' : status === 'warm' || status === 'cold' || status === 'suspended' ? 'asleep' : status

export function setup(ctx: PanelContext): void {
  ctx.subscriptions.push(
    plugin.on('sprites.checkpointed', ({ name, run, ok, message }) => {
      if (waiting[name] !== undefined && waiting[name] !== run) return
      delete waiting[name]
      setBusy(name, null)
      set(notice, { tone: ok ? 'success' : 'danger', title: ok ? 'Checkpoint created' : 'Checkpoint failed', text: `${name}: ${message}` })
    })
  )
  void refresh()
}

function SpriteItem({ sprite }: { sprite: SpriteRow }) {
  const doing = read(busy)[sprite.name]
  const gone = sprite.status === 'gone'
  return (
    <ListItem title={sprite.workspace ?? sprite.name} description={`${sprite.name} · ${sprite.org}`} icon="cloud">
      <Stack gap="xs">
        <Row gap="xs" align="center" wrap>
          <Badge tone={tone(sprite.status)}>{label(sprite.status)}</Badge>
          {sprite.createdAt ? (
            <Text muted size="xs">
              created <RelativeTime at={sprite.createdAt} />
            </Text>
          ) : null}
        </Row>
        <Row gap="xs" align="center" wrap>
          {doing ? <Spinner label={doing} /> : null}
          {gone ? (
            <Button size="xs" variant="outline" icon="close" disabled={Boolean(doing)} onPress={() => void forget(sprite.name)}>
              Forget
            </Button>
          ) : (
            <>
              <Button
                size="xs"
                variant="outline"
                icon="open-external"
                disabled={!sprite.url}
                onPress={() => sprite.url && shell.openExternal(sprite.url)}
              >
                Open URL
              </Button>
              <Button size="xs" variant="outline" icon="check" disabled={Boolean(doing)} onPress={() => void checkpoint(sprite.name)}>
                Checkpoint
              </Button>
            </>
          )}
        </Row>
      </Stack>
    </ListItem>
  )
}

export default function Panel() {
  const list = read(sprites)
  const n = read(notice)
  return (
    <Stack gap="md">
      <Row justify="between" align="center">
        <Text weight="semibold">Sprites created by Orca</Text>
        <IconButton
          icon="refresh"
          label="Refresh"
          size="sm"
          variant="ghost"
          disabled={read(loading)}
          onPress={() => void refresh()}
        />
      </Row>
      {read(error) ? (
        <Callout tone="warning" title="Could not read Sprite states">
          {read(error)}
        </Callout>
      ) : null}
      {n ? (
        <Callout tone={n.tone} title={n.title}>
          {n.text}
        </Callout>
      ) : null}
      {list === null ? (
        read(error) ? null : <Spinner label="Loading Sprites" />
      ) : list.length === 0 ? (
        <EmptyState
          icon="cloud"
          title="No Sprites yet"
          description="Create a workspace with Run on → Per-Workspace Environment → Sprites."
        />
      ) : (
        <List label="Sprites">
          {list.map((sprite) => (
            <SpriteItem sprite={sprite} />
          ))}
        </List>
      )}
      <Text muted size="xs">
        Deleting a workspace in Orca destroys its Sprite. A Sprite left behind by a failed create:
        Settings → Cloud VMs → Cleanup.
      </Text>
    </Stack>
  )
}
