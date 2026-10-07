import type { ClientModule } from 'claude-code'

type RowProps = {
  id: string
  label: string
  origin: string
  body: string
  reason: string
  isChecked: boolean
  isMaybe: boolean
}

const Row: ClientModule<RowProps, { isHovered: boolean }> = (props, surface) => {
  if (surface.state === undefined) {
    surface.onPointer(e => {
      if (e.type === 'down' && e.button === 'left') surface.post('toggle')
      if (e.type === 'enter' || e.type === 'leave') surface.setState({ isHovered: e.type === 'enter' })
    })
    surface.setState({ isHovered: false })
  }
  const { Box, Text } = surface.elements
  const isHovered = surface.state?.isHovered === true
  const background = isHovered ? 'userMessageBackgroundHover' : 'userMessageBackground'
  const style = props.isChecked
    ? { strikethrough: true, dimColor: true }
    : props.isMaybe
      ? { italic: true, dimColor: true }
      : {}

  return (
    <Box flexDirection="column" paddingX={2} paddingY={0.5} backgroundColor={background}>
      <Box flexDirection="row">
        <Box flexGrow={1} flexDirection="row">
          {props.label !== '' && <Text bold={!props.isChecked} dimColor={props.isChecked}>{props.label}</Text>}
          {props.origin !== '' && <Text dimColor>{props.origin}  </Text>}
          <Text wrap="wrap" {...style}>
            {props.body}
          </Text>
        </Box>
        {props.id !== '' && <Text dimColor>{`  ${props.id}`}</Text>}
      </Box>
      {props.reason !== '' && !props.isChecked && <Text dimColor>{`possibly handled: ${props.reason}`}</Text>}
    </Box>
  )
}

export default Row
