require 'tk'
require 'gosu'
require 'thread'
require 'net/http'
require 'json'
require 'open3'
require 'httpx'

class GrammarChecker
    def initialize(host: 'localhost', port: 8081)
    @uri = URI("http://#{host}:#{port}/v2/check")
  end

  def check_text(text)
    return [] if text.strip.empty?

    request = Net::HTTP::Post.new(@uri)
    request.set_form_data({
      'language' => 'it',
      'text' => text
    })

    response = Net::HTTP.start(@uri.hostname, @uri.port) do |http|
      http.request(request)
    end

    parse_response(JSON.parse(response.body))
  rescue StandardError => e
    puts "Grammar check error: #{e.message}"
    []
  end

  private

  def parse_response(json)
    json['matches'].map do |match|
      {
        error_text: match['context']['text'][match['offset'], match['length']],
        message: match['message'],
        suggestions: match['replacements'].map { |r| r['value'] },
        position: match['offset'],
        length: match['length']
      }
    end
  end
end

class WordProcessor
  DEFAULT_FONT = { 'family' => 'Topaz a600a1200a400', 'size' => 16 }.freeze
  AUTOSAVE_INTERVAL = 300 # 5 minutes
  CACHE_SIZE_LIMIT = 1000
  ENTER_SYMBOL = "\u21B5" # Oppure \u2324 -->Simbolo per il tasto Enter

  def initialize
    @languagetool_process = start_languagetool_server
    at_exit { stop_languagetool_server }  # Arresta il server quando l'app si chiude

    @file_path = nil
    @replacement_enabled = true
    @replacement_cache = {}
    @sound_enabled = false
    @capitalize_next = false
    @after_period = false
    @grammar_checker = GrammarChecker.new
    @grammar_check_enabled = false

    setup_window
    setup_text_area
    setup_scrollbar
    setup_menu
    setup_grammar_highlight
    setup_special_chars_display
    load_replacements
    start_autosave_thread
    start_grammar_check_thread
    bind_key_events

    @sound_player = SoundPlayer.new('/home/Giuse/Musica/Effetti/click.wav')

    # *** API Key Gemini - Assicurati di impostarla! ***
    @gemini_api_key = ENV['GOOGLE_API_KEY'] || 'YOUR_API_KEY' # *** SOSTITUISCI 'YOUR_API_KEY' ***
    @gemini_api_url_base = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-thinking-exp-01-21:generateContent" # URL base
  end

  def setup_special_chars_display
    # Configura il tag per il simbolo Enter con colore blu
    @text.tag_configure('enter_symbol',
      foreground: 'red',    # colore "enter"
      elide: false          # Non nascondere il simbolo
    )
  end

   def setup_grammar_highlight
    @text.tag_configure('error', underline: true, foreground: 'red')
  end

  def start_grammar_check_thread
    Thread.new do
      loop do
        sleep 2  # Controlla ogni 2 secondi
        check_grammar if @grammar_check_enabled
      end
    end
  end

  def check_grammar
    # Rimuovi i tag esistenti
    @text.tag_remove('error', '1.0', 'end')

    # Ottieni il testo corrente
    text = @text.get('1.0', 'end')

    # Controlla la grammatica
    errors = @grammar_checker.check_text(text)

    # Evidenzia gli errori
    errors.each do |error|
      start_pos = calculate_text_position(text, error[:position])
      end_pos = calculate_text_position(text, error[:position] + error[:length])

      @text.tag_add('error', start_pos, end_pos)

      # Aggiungi tooltip con suggerimenti
      @text.tag_bind('error', 'Enter') do |e|
        show_error_tooltip(e, error[:message], error[:suggestions])
      end

      @text.tag_bind('error', 'Leave') do
        hide_error_tooltip
      end
    end
  end

  def calculate_text_position(text, offset)
    line = 1
    col = 0
    current_offset = 0

    text.each_char do |char|
      break if current_offset == offset

      if char == "\n"
        line += 1
        col = 0
      else
        col += 1
      end
      current_offset += 1
    end

    "#{line}.#{col}"
  end

  def show_error_tooltip(event, message, suggestions)
    @tooltip.destroy if @tooltip

    @tooltip = TkToplevel.new do
      overrideredirect true
      geometry "+#{event.x_root}+#{event.y_root + 20}"
    end

    TkLabel.new(@tooltip) do
      text "#{message}\nSuggerimenti: #{suggestions.join(', ')}"
      pack
    end
  end

  def hide_error_tooltip
    @tooltip.destroy if @tooltip
    @tooltip = nil
  end


  # Metodi pubblici per la gestione dei file
  def open_file
    file_path = Tk.getOpenFile
    return if file_path.empty?

    begin
      content = File.read(file_path)
      @text.delete('1.0', 'end')

      # Dividi il contenuto in linee, mantieni i fine riga originali
      lines = content.split(/(?<=\n)/)

      lines.each_with_index do |line, index|
        # Rimuovi il newline esistente se presente
        line_without_newline = line.chomp

        # Se non è l'ultima linea e la linea non è vuota
        if index < lines.length - 1 && !line_without_newline.empty?
          # Inserisci la linea, il simbolo enter e poi il newline
          @text.insert('end', line_without_newline)
          symbol_pos = @text.index('end-1c')
          @text.insert('end', "#{ENTER_SYMBOL}\n")

          # Applica il tag solo al simbolo Enter
          @text.tag_add('enter_symbol', symbol_pos, "#{symbol_pos}+1c")
        else
          # Per l'ultima linea o linee vuote, inserisci solo il contenuto
          @text.insert('end', line)
        end
      end

      @file_path = file_path
    rescue StandardError => e
      Tk.messageBox(
        type: 'error',
        message: "Errore nell'apertura del file: #{e.message}"
      )
    end
  end

   def save_file
    file_path = Tk.getSaveFile
    return if file_path.empty?

    begin
      # Ottieni il contenuto rimuovendo i simboli Enter visibili
      content = @text.get('1.0', 'end').gsub(ENTER_SYMBOL, '')
      File.write(file_path, content)
      @file_path = file_path
    rescue StandardError => e
      Tk.messageBox(
        type: 'error',
        message: "Errore nel salvataggio del file: #{e.message}"
      )
    end
  end

def show_scrollable_message(title, message)
  dialog = TkToplevel.new
  dialog.title = title
  dialog.geometry("800x300")

  frame = TkFrame.new(dialog) { pack(fill: 'both', expand: true) }

  text = TkText.new(frame) do
    wrap 'word'
    state 'normal'
    insert '1.0', message
    state 'disabled'
    pack(fill: 'both', expand: true)
    configure('font' => ['Calibri', 12])
  end

  scrollbar = TkScrollbar.new(frame) do
    orient 'vertical'
    command proc { |*args| text.yview(*args) }
    pack(side: 'right', fill: 'y')
  end

  text.yscrollcommand(proc { |first, last| scrollbar.set(first, last) })

  TkButton.new(dialog) do
    text 'OK'
    command { dialog.destroy }
    pack(pady: 10)
  end
end

  # Metodo per processare il testo selezionato con Gemini
  def process_selected_text_with_gemini(ai_action) # Aggiunto ai_action per specificare l'azione AI
    selection_range = @text.tag_ranges('sel')
    if selection_range.empty?
      Tk.messageBox(type: 'warning', message: 'Seleziona del testo per processarlo con AI.')
      return
    end

    selected_text = @text.get('sel.first', 'sel.last')
    prompt_prefix = get_prompt_prefix(ai_action) # Ottieni il prefisso del prompt in base all'azione
    full_prompt = "#{prompt_prefix} #{selected_text}"
    
    gemini_response_text = generate_content(full_prompt) # Usa la funzione HTTPX

    confirm = show_scrollable_message("Risultato AI", gemini_response_text)

    rescue StandardError => e
      Tk.messageBox(type: 'error', message: "Errore AI: #{e.message}")
      puts "Errore AI: #{e.message}" # Log per debug
    
  end

  # Funzione per generare contenuto con HTTPX verso API Gemini
  def generate_content(prompt)
    url = "#{@gemini_api_url_base}?key=#{@gemini_api_key}"

    response = HTTPX.post(url, json: {
      "contents" => [{ "parts" => [{ "text" => prompt }] }]
    })

    case response.status
    when 200
      data = JSON.parse(response.body)
      return data.dig("candidates", 0, "content", "parts", 0, "text") || "Risposta vuota!"
    when 400
      return "Errore 400: Richiesta non valida. Controlla il formato del JSON."
    when 401
      return "Errore 401: API Key non valida o mancante!"
    when 403
      return "Errore 403: Accesso negato. Verifica i permessi API."
    when 404
      return "Errore 404: Modello o endpoint non trovato."
    when 500
      return "Errore 500: Problema interno ai server di Google."
    else
      return "Errore #{response.status}: #{response.body}"
    end
  rescue StandardError => e
    return "Errore durante la richiesta API: #{e.message}"
  end


  def get_prompt_prefix(ai_action)
    case ai_action
    when 'sinonimo'
      "Trova un sinonimo per la seguente parola/frase:"
    when 'migliora testo'
      "Migliora la seguente frase rendendola più chiara e scorrevole:"
    when 'riscrivi testo'
      "Riscrivi il seguente testo in modo diverso, mantenendo lo stesso significato:"
    when 'arrichisci testo'
      "Arricchisci il seguente testo aggiungendo dettagli e rendendolo più descrittivo:"
    else
      "Processa il seguente testo:" # Default, nel caso non corrisponda a nessuna azione specifica
    end
  end


  private

  def setup_window
    @root = TkRoot.new
    @root.title('Word Processor by Giuseppe Bassan e AI')
  end

  def setup_text_area
    @text = TkText.new(@root) do
      width 100
      height 40
      font TkFont.new(DEFAULT_FONT)
      insertbackground 'blue'
      blockcursor true
      insertofftime 0
      wrap 'word'
      selectbackground 'lightblue' # Colore di sfondo per il testo selezionato
      selectforeground 'black'   # Colore del testo selezionato
      pack('side' => 'left', 'fill' => 'both', 'expand' => true, 'padx' => 10, 'pady' => 10)
    end
  end

  def setup_scrollbar
    scrollbar = TkScrollbar.new(@root) do
      orient 'vertical'
      command proc { |*args| @text.yview(*args) }
      pack('side' => 'right', 'fill' => 'y')
    end

    @text.yscrollcommand(proc { |first, last| scrollbar.set(first, last) })
  end

  def setup_menu
    menu_bar = TkMenu.new(@root)
    @root.menu(menu_bar)

    setup_file_menu(menu_bar)
    setup_settings_menu(menu_bar)
    setup_ai_menu(menu_bar) 
  end

  def setup_file_menu(menu_bar)
    file_menu = TkMenu.new(menu_bar)
    menu_bar.add(:cascade, menu: file_menu, label: 'File')

    file_menu.add(:command, label: 'Open', command: -> { open_file })
    file_menu.add(:command, label: 'Save', command: -> { save_file })
    file_menu.add(:command, label: 'Exit', command: -> { exit })
  end

  def setup_settings_menu(menu_bar)
    settings_menu = TkMenu.new(menu_bar)
    menu_bar.add(:cascade, menu: settings_menu, label: 'Settings')

    settings_menu.add(:command, label: 'Enable Sound', command: -> { @sound_enabled = true })
    settings_menu.add(:command, label: 'Disable Sound', command: -> { @sound_enabled = false })
    settings_menu.add(:command, label: 'Enable Replacement', command: -> { @replacement_enabled = true })
    settings_menu.add(:command, label: 'Disable Replacement', command: -> { @replacement_enabled = false })
    settings_menu.add(:command, label: 'Enable Grammar Check', command: -> { @grammar_check_enabled = true })
    settings_menu.add(:command, label: 'Disable Grammar Check', command: -> { @grammar_check_enabled = false })
    settings_menu.add(:command, label: 'Clear Replacement Cache', command: -> { @replacement_cache.clear })
  end

  def setup_ai_menu(menu_bar)
    ai_menu = TkMenu.new(menu_bar)
    menu_bar.add(:cascade, menu: ai_menu, label: 'AI')

    ai_menu.add(:command, label: 'Sinonimo', command: -> { process_selected_text_with_gemini('sinonimo') })
    ai_menu.add(:command, label: 'Migliora testo', command: -> { process_selected_text_with_gemini('migliora testo') })
    ai_menu.add(:command, label: 'Riscrivi testo', command: -> { process_selected_text_with_gemini('riscrivi testo') })
    ai_menu.add(:command, label: 'Arrichisci testo', command: -> { process_selected_text_with_gemini('arrichisci testo') })
  end


  def load_replacements
    @replacements = {}
    File.foreach('replacements.txt') do |line|
      wrong, correct = line.chomp.split(' ', 2)
      @replacements[wrong] = correct if wrong && correct
    end
  rescue Errno::ENOENT
    puts 'Warning: replacements.txt not found'
    @replacements = {}
  end

  def start_autosave_thread
    Thread.new do
      loop do
        sleep AUTOSAVE_INTERVAL
        autosave
      end
    end
  end

  def autosave
    return unless @file_path

    begin
      timestamp = Time.now.strftime('%Y%m%d%H%M%S')
      autosave_path = "#{@file_path}_autosave_#{timestamp}.txt"

      # Ottieni il contenuto rimuovendo i simboli Enter visibili
      content = @text.get('1.0', 'end').gsub(ENTER_SYMBOL, '')

      File.write(autosave_path, content)
      puts "Autosave completato: #{autosave_path}"
    rescue StandardError => e
      puts "Autosave fallito: #{e.message}"
    end
  end

 def bind_key_events
    @text.bind('KeyPress') do |event|
      handle_key_press(event)
    end

    # Modifica il binding per Return per usare KeyPress invece di Return
    @text.bind('KeyPress-Return') do |event|
      handle_return_key
    end
    
     @text.bind("Tab") do
     @text.insert("insert", "    ")  # 4 spazi
      Tk.callback_break  # Evita il comportamento predefinito
    end
    
    
  end

  def handle_key_press(event)
    key = event.keysym

    play_sound(key)

    case key
    when 'period'
      handle_period
    when /^[a-zA-Z]$/
      handle_letter(key)
    when 'space'
      handle_space
    when 'comma', 'semicolon', 'colon'
      handle_punctuation(key)
    else
      @capitalize_next = false unless key == 'Return'
    end
  end

  def play_sound(key)
    return unless @sound_enabled
    return if %w[Shift_L Shift_R Control_L Control_R Alt_L ISO_Level3_Shift].include?(key)

    @sound_player.play_sound
  end

   def handle_period
    @last_period_position = @text.index('insert')
    @text.insert('insert', '. ')
    @capitalize_next = true
    Tk.callback_break
  end

   def handle_return_key
    current_pos = @text.index('insert')

    # Controlla e rimuovi lo spazio dopo il punto se necessario
    if @last_period_position
      last_char = @text.get("#{current_pos} - 1 chars", current_pos)
      prev_char = @text.get("#{current_pos} - 2 chars", "#{current_pos} - 1 chars")

      if last_char == ' ' && prev_char == '.'
        @text.delete("#{current_pos} - 1 chars", current_pos)
        current_pos = @text.index('insert')
      end
    end

    # Inserisci il simbolo Enter alla posizione corrente
    symbol_pos = @text.index('insert')
    @text.insert('insert', "#{ENTER_SYMBOL}\n")

    # Applica il tag solo al simbolo Enter
    @text.tag_add('enter_symbol', symbol_pos, "#{symbol_pos}+1c")

    Tk.callback_break
  end

  def handle_letter(key)
    if @capitalize_next
      @text.insert('insert', key.upcase)
      @capitalize_next = false
      Tk.callback_break
    end
  end

  def handle_space
    replace_word if @replacement_enabled
  end

  def handle_punctuation(key)
    return unless @replacement_enabled

    Tk.after(10) { replace_with_punctuation(key) }
  end

  def replace_word
    current_pos = @text.index('insert')
    line_start = "#{current_pos.split('.').first}.0"
    line_text = @text.get(line_start, 'insert')

    return if @replacement_cache.key?(line_text)

    new_text = apply_replacements(line_text)
    update_text_and_cache(line_start, line_text, new_text) if new_text != line_text
  end

  def apply_replacements(text)
    result = text.dup
    @replacements.each do |wrong, correct|
      result.gsub!(/\b#{Regexp.escape(wrong)}(?!\w)/, correct)
    end
    result
  end

  def update_text_and_cache(line_start, original_text, new_text)
    @replacement_cache.shift if @replacement_cache.size >= CACHE_SIZE_LIMIT
    @replacement_cache[original_text] = new_text

    @text.delete(line_start, 'insert')
    @text.insert(line_start, new_text)
  end

   private

  def start_languagetool_server
    puts "Avvio del server LanguageTool..."
    command = "java -cp '/usr/share/languagetool/*' org.languagetool.server.HTTPServer --port 8081"

    stdin, stdout, stderr, wait_thr = Open3.popen3(command)

    Thread.new do
      stdout.each { |line| puts "LT: #{line}" }
    end

    Thread.new do
      stderr.each { |line| puts "LT ERR: #{line}" }
    end

    wait_thr
  end

  def stop_languagetool_server
    return unless @languagetool_process

    puts "Arresto del server LanguageTool..."
    Process.kill("TERM", @languagetool_process.pid)
    @languagetool_process = nil
  rescue StandardError => e
    puts "Errore nell'arresto del server: #{e.message}"
  end

end

def replace_with_punctuation(punctuation_key)
  return unless @replacement_enabled

  current_pos = @text.index('insert')
  line_start = "#{current_pos.split('.').first}.0"
  line_text = @text.get(line_start, 'insert')

  # Controlla se il testo è già nella cache
  return if @replacement_cache.key?(line_text)

  # Salva il testo originale per confronto
  original_line_text = line_text.dup
  modified = false

  # Esegui le sostituzioni per le parole che precedono la punteggiatura
  @replacements.each do |wrong, correct|
    if line_text.match?(/\b#{Regexp.escape(wrong)}[,;:.]\s*$/)
      line_text.gsub!(/\b#{Regexp.escape(wrong)}([,;:.])\s*$/, "#{correct}\\1 ")
      modified = true
    end
  end

  # Gestione specifica per ogni tipo di punteggiatura
  case punctuation_key
  when 'comma'
    line_text.gsub!(/,\s*$/, ', ')
    modified = true
  when 'semicolon'
    line_text.gsub!(/;\s*$/, '; ')
    modified = true
  when 'colon'
    line_text.gsub!(/:\s*$/, ': ')
    modified = true
  end

  # Se sono state fatte modifiche, aggiorna la cache e il testo
  if modified && line_text != original_line_text
    # Gestione della dimensione della cache
    @replacement_cache.shift if @replacement_cache.size >= self.class::CACHE_SIZE_LIMIT
    @replacement_cache[original_line_text] = line_text

    # Aggiorna il testo nell'editor
    @text.delete(line_start, 'insert')
    @text.insert(line_start, line_text)
  end
end

class SoundPlayer
  def initialize(sound_file)
    @sound = Gosu::Sample.new(sound_file)
  rescue StandardError => e
    puts "Failed to load sound: #{e.message}"
    @sound = nil
  end

  def play_sound
    @sound&.play
  end
end

# Avvio Applicazione
WordProcessor.new
Tk.mainloop
