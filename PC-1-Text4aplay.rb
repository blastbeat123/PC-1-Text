#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

# Autore: Giuseppe Bassan
# Word Processor ispirato a C1-Text per Amiga


require 'tk'
require 'thread'
require 'net/http'
require 'json'
require 'open3'
require 'httpx'
require 'yaml'

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
  AUTOSAVE_INTERVAL = 600 # 300 = 5 minutes
  CACHE_SIZE_LIMIT = 1000
  ENTER_SYMBOL = "\u21B5" # Oppure \u2324 -->Simbolo per il tasto Enter
  MAX_GRAMMAR_CHECK_SIZE = 100_000  # 100KB limite per controllo automatico
  
  # ----- INTERFACCIA PUBBLICA ---------------------------------------
  
  def initialize
    config_path = File.join(__dir__, 'settings.yml')
    settings = YAML.load_file(config_path)

    font_settings = settings['default_font']
    @default_font = TkFont.new('family' => font_settings['family'], 'size' => font_settings['size'])
    @current_font_name = font_settings['family']
    @cursor_color = settings['cursor_color']
    @default_file_path = settings['default_file_path'] || Dir.pwd  # Fallback alla directory corrente
    
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
    @error_tags = []
    @error_tag_counter = 0
    @grammar_check_thread_running = false
    @tooltip = nil
    @grammar_check_thread = nil  
    @last_period_position = nil
    
    setup_window
    setup_text_and_scrollbar
    setup_menu
    setup_grammar_highlight
    setup_special_chars_display
    load_replacements
    start_autosave_thread
    start_grammar_check_thread
    bind_key_events
    @sound_player = SoundPlayer.new('click.wav')
    @notification_sound = SoundPlayer.new('click2.wav')
    # *** API Key Gemini ***
    @gemini_api_key = ENV['GOOGLE_API_KEY']
    @gemini_api_url_base = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-thinking-exp-01-21:generateContent" # URL base
    update_window_title
  end
  
  def open_file
    file_path = Tk.getOpenFile(initialdir: @default_file_path)
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
        if index < lines.length - 1
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
      update_window_title
      
      # Aggiorna il percorso predefinito alla directory del file appena aperto
      @default_file_path = File.dirname(file_path)
              
    rescue StandardError => e
      Tk.messageBox(
        icon: 'error',
        type: 'ok', 
        message: "Errore nell'apertura del file: #{e.message}"
      )
    end
  end
  
  def save_file
    # Salvataggio veloce - usa il percorso del file corrente se disponibile
    if @file_path && !@file_path.empty?
      begin
        # Ottieni il contenuto rimuovendo i simboli Enter visibili
        content = @text.get('1.0', 'end').gsub(ENTER_SYMBOL, '')
        File.write(@file_path, content)
        puts "File salvato: #{@file_path}"
      rescue StandardError => e
        Tk.messageBox(
          icon: 'error',
          type: 'ok',
          message: "Errore nel salvataggio del file: #{e.message}"
        )
      end
    else
      # Se non c'è un file corrente, comportati come "Save As"
      save_as_file
    end
  end
  
  def save_as_file
    file_path = Tk.getSaveFile(initialdir: @default_file_path)
    return if file_path.empty?

    begin
      # Ottieni il contenuto rimuovendo i simboli Enter visibili
      content = @text.get('1.0', 'end').gsub(ENTER_SYMBOL, '')
      File.write(file_path, content)
      @file_path = file_path
      
      update_window_title
      
      # Aggiorna il percorso predefinito alla directory del file appena salvato
      @default_file_path = File.dirname(file_path)
      
    rescue StandardError => e
      Tk.messageBox(
        icon: 'error',
        type: 'ok',
        message: "Errore nel salvataggio del file: #{e.message}"
      )
    end
  end
 
  def process_selected_text_with_gemini(ai_action)
    # Metodo per processare il testo selezionato con Gemini
    selection_range = @text.tag_ranges('sel')
    if selection_range.empty?
      Tk.messageBox(icon: 'warning', type: 'ok', message: 'Seleziona del testo per processarlo con AI.')
      return
    end

    # Mostra il messaggio di attesa
    waiting_dialog = show_waiting_message("Elaborazione in corso...", "Attendere, sto elaborando la richiesta AI...")

    # Esegui il processo AI in un thread separato per non bloccare l'interfaccia
    Thread.new do
      begin
        selected_text = @text.get('sel.first', 'sel.last')
        prompt_prefix = get_prompt_prefix(ai_action)
        full_prompt = "#{prompt_prefix} #{selected_text}"
    
        gemini_response_text = generate_content(full_prompt)
    
        # Chiudi il messaggio di attesa in modo sicuro
        Tk.after(0) do
          begin
            waiting_dialog.destroy if waiting_dialog
          rescue StandardError => e
            puts "Errore durante la chiusura del dialogo: #{e.message}"
          end
        end
    
        # Mostra il risultato
        show_scrollable_message("Risultato AI", gemini_response_text)
      rescue StandardError => e
        # Chiudi il messaggio di attesa anche in caso di errore
        Tk.after(0) do
          begin
            waiting_dialog.destroy if waiting_dialog
          rescue StandardError => e
            puts "Errore durante la chiusura del dialogo: #{e.message}"
          end
        end
    
        Tk.messageBox(type: 'error', message: "Errore AI: #{e.message}")
        puts "Errore AI: #{e.message}" # Log per debug
      end
    end
  end

  private

  # ----- SETUP E INIZIALIZZAZIONE -----------------------------------
  
  def setup_window
    @root = TkRoot.new
    @root.title('Word Processor by Giuseppe Bassan e AI')
    @root.geometry('1200x900')  # Imposta dimensioni fisse per la finestra
  end

  def setup_text_and_scrollbar
    # Crea un frame per contenere sia text che scrollbar
    frame = TkFrame.new(@root)
    frame.pack(fill: 'both', expand: true, padx: 10, pady: 10)

    # Crea la scrollbar
    scrollbar = TkScrollbar.new(frame)
    scrollbar.pack(side: 'right', fill: 'y')

    # Crea il text widget
    @text = TkText.new(frame) do
      blockcursor true
      insertofftime 0
      wrap 'word'
      selectbackground 'lightblue' # Colore di sfondo per il testo selezionato
      selectforeground 'black' # Colore del testo selezionato
      pack(side: 'left', fill: 'both', expand: true)
    end
    @text.configure(
      'font' => @default_font,
      'insertbackground' => @cursor_color
    )
       
    # Collega text e scrollbar in entrambe le direzioni
    @text.yscrollcommand(proc { |first, last| scrollbar.set(first, last) })
    scrollbar.command(proc { |*args| @text.yview(*args) })
  end

  def setup_menu
    menu_bar = TkMenu.new(@root)
    @root.menu(menu_bar)
    setup_file_menu(menu_bar)
    setup_settings_menu(menu_bar)
    setup_ai_menu(menu_bar)
    setup_font_menu(menu_bar)
    setup_context_menu
    setup_abbreviations_menu(menu_bar)
  end
 def setup_font_menu(menu_bar)
  font_menu = TkMenu.new(menu_bar)
  menu_bar.add(:cascade, menu: font_menu, label: 'Font')

  # Ottieni i font disponibili
  available_fonts = get_available_fonts

  # Ordina i font in ordine alfabetico
  sorted_fonts = available_fonts.sort

  # Crea gruppi alfabetici
  font_groups = Hash.new { |hash, key| hash[key] = [] }
  sorted_fonts.each do |font|
    initial_letter = font[0].upcase  # Prendi la prima lettera del font
    font_groups[initial_letter] << font
  end

  
  font_groups.sort.each do |initial_letter, fonts|
    if fonts.length > 35  # Se ci sono più di 35 font in un gruppo
      # Dividi il gruppo in sottogruppi più piccoli
      submenu = TkMenu.new(font_menu)
      font_menu.add(:cascade, menu: submenu, label: initial_letter)
      
      # Crea sottogruppi di massimo 15 font ciascuno
      fonts.each_slice(15).with_index do |font_slice, index|
        slice_submenu = TkMenu.new(submenu)
        start_font = font_slice.first[0..3]  # Prime 4 lettere del primo font
        end_font = font_slice.last[0..3]     # Prime 4 lettere dell'ultimo font
        submenu.add(:cascade, menu: slice_submenu, label: "#{start_font}...#{end_font}")
        
        font_slice.each do |font|
          slice_submenu.add(:command, label: font, command: -> { change_font(font) })
        end
      end
    else
      # Gruppo normale per lettere con pochi font
      submenu = TkMenu.new(font_menu)
      font_menu.add(:cascade, menu: submenu, label: initial_letter)

      fonts.each do |font|
        submenu.add(:command, label: font, command: -> { change_font(font) })
      end
    end
   end
  end
  
  def setup_file_menu(menu_bar)
    file_menu = TkMenu.new(menu_bar)
    menu_bar.add(:cascade, menu: file_menu, label: 'File')
    file_menu.add(:command, label: 'Open', command: -> { open_file })
    file_menu.add(:command, label: 'Save', accelerator: 'Ctrl+S', command: -> { save_file })
    file_menu.add(:command, label: 'Save As', accelerator: 'Ctrl+Shift+S', command: -> { save_as_file })
    file_menu.add(:command, label: 'Exit', command: -> { exit })
  end
  
  def setup_settings_menu(menu_bar)
    settings_menu = TkMenu.new(menu_bar)
    menu_bar.add(:cascade, menu: settings_menu, label: 'Settings')

    settings_menu.add(:command, label: 'Enable Sound', command: -> { @sound_enabled = true })
    settings_menu.add(:command, label: 'Disable Sound', command: -> { @sound_enabled = false })
    settings_menu.add(:command, label: 'Enable Replacement', command: -> { @replacement_enabled = true })
    settings_menu.add(:command, label: 'Disable Replacement', command: -> { @replacement_enabled = false })
    settings_menu.add(:command, label: 'Enable Grammar Check', command: -> { 
      @grammar_check_enabled = true 
      start_grammar_check_thread unless @grammar_check_thread_running
    })
  
    settings_menu.add(:command, label: 'Disable Grammar Check', command: -> { 
      @grammar_check_enabled = false
      stop_grammar_check_thread
      remove_all_error_tags
    })
      
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
  
  def setup_abbreviations_menu(menu_bar)
    abbrev_menu = TkMenu.new(menu_bar)
    menu_bar.add(:cascade, menu: abbrev_menu, label: 'Sostituzioni')

    abbrev_menu.add(:command, label: 'Mostra elenco', command: proc { show_abbreviations_window })
  end
  
  def setup_context_menu
    @context_menu = TkMenu.new(@root, tearoff: 0) # tearoff: 0 rimuove la linea tratteggiata di "separazione"

    @context_menu.add(:command, label: 'Taglia', command: proc { cut_text })
    @context_menu.add(:command, label: 'Copia', command: proc { copy_text })
    @context_menu.add(:command, label: 'Incolla', command: proc { paste_text })
    @context_menu.add(:separator) # Aggiunge una linea di separazione nel menu
    @context_menu.add(:command, label: 'Controlla grammatica (selezione)', command: proc { check_selected_grammar })
    @context_menu.add(:command, label: 'Disabilita controllo grammaticale', command: proc {
      @grammar_check_enabled = false
      stop_grammar_check_thread
      remove_all_error_tags
    })
    @context_menu.add(:separator) # Aggiunge una linea di separazione nel menu
    @context_menu.add(:command, label: 'Sinonimo (AI)', command: -> { process_selected_text_with_gemini('sinonimo') })
    @context_menu.add(:command, label: 'Migliora testo (AI)', command: -> { process_selected_text_with_gemini('migliora testo') })
    # ... (aggiungi altre voci di menu AI se vuoi nel menu contestuale)

    # Associa l'evento del click destro al widget @text
    @text.bind('ButtonRelease-3') do |event|
      @context_menu.popup(event.x_root, event.y_root) # Mostra il menu alle coordinate del mouse
      Tk.callback_break 
    end
  end
  
  def setup_grammar_highlight
    @text.tag_configure('error', underline: true, foreground: 'red')
  end
         
  def setup_special_chars_display
    # Configura il tag per il simbolo Enter con colore rosso
    @text.tag_configure('enter_symbol',
      foreground: 'red',    # colore "enter"
      elide: false          # Non nascondere il simbolo
    )
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
    
    # Aggiunge il binding per Ctrl+S (salvataggio veloce)
    @text.bind('Control-s') do
      save_file
      Tk.callback_break  # Evita il comportamento predefinito
    end
      
    # Opzionalmente, puoi aggiungere anche Ctrl+Shift+S per Save As
    @text.bind('Control-Shift-S') do
      save_as_file
      Tk.callback_break
    end   
  end
  
  
  # ----- GESTIONE EVENTI --------------------------------------------
  
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
    when 'guillemotright'  # Questo è il keysym per »
      handle_closing_quote
    else
      @capitalize_next = false unless key == 'Return'
    end
  end
  
  # NUOVO METODO GENERICO per rimuovere spazio dopo il punto
  def remove_space_after_period_if_needed
    return unless @last_period_position
  
    current_pos = @text.index('insert')
    last_char = @text.get("#{current_pos} - 1 chars", current_pos)
    prev_char = @text.get("#{current_pos} - 2 chars", "#{current_pos} - 1 chars")

    if last_char == ' ' && prev_char == '.'
      @text.delete("#{current_pos} - 1 chars", current_pos)
    end
  end
  
    
  def handle_return_key
    remove_space_after_period_if_needed

    # Inserisci il simbolo Enter alla posizione corrente
    symbol_pos = @text.index('insert')
    @text.insert('insert', "#{ENTER_SYMBOL}\n")

    # Applica il tag solo al simbolo Enter
    @text.tag_add('enter_symbol', symbol_pos, "#{symbol_pos}+1c")

    Tk.callback_break
  end
  
  def handle_closing_quote
    remove_space_after_period_if_needed

    # Inserisci la virgoletta di chiusura
    @text.insert('insert', '»')
    Tk.callback_break
  end
  
  def handle_letter(key)
    if @capitalize_next
      @text.insert('insert', key.upcase)
      @capitalize_next = false
      show_replacement_notification("lettera maiuscola")
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

  def handle_period
    # Prima controlla e sostituisci la parola se necessario
    word_replaced = replace_with_punctuation_for_period if @replacement_enabled

    @last_period_position = @text.index('insert')
    @text.insert('insert', '. ')
    
    # Mostra notifica appropriata
    if word_replaced
      show_replacement_notification("sostituita parola - inserito spazio")
    else
      show_replacement_notification("inserito spazio")
    end
    
    @capitalize_next = true
    Tk.callback_break
  end


  #----- UTILITA' INTERNE ---------------------------------------------

  def replace_word
    current_pos = @text.index('insert')
    line_start = "#{current_pos.split('.').first}.0"
    line_text = @text.get(line_start, 'insert')

    return if @replacement_cache.key?(line_text)

    new_text = apply_replacements(line_text)
    update_text_and_cache(line_start, line_text, new_text) if new_text != line_text
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
    word_replaced = false

    # Esegui le sostituzioni per le parole che precedono la punteggiatura
    @replacements.each do |wrong, correct|
      if line_text.match?(/\b#{Regexp.escape(wrong)}[,;:.]\s*$/)
        line_text.gsub!(/\b#{Regexp.escape(wrong)}([,;:.])\s*$/, "#{correct}\\1 ")
        modified = true
        word_replaced = true
      end
    end

    # Gestione specifica per ogni tipo di punteggiatura
    space_added = false
    case punctuation_key
    when 'comma'
      if line_text.gsub!(/,\s*$/, ', ')
        modified = true
        space_added = true
      end
    when 'semicolon'
      if line_text.gsub!(/;\s*$/, '; ')
        modified = true
        space_added = true
      end
    when 'colon'
      if line_text.gsub!(/:\s*$/, ': ')
        modified = true
        space_added = true
      end
    end

    # Se sono state fatte modifiche, aggiorna la cache e il testo
    if modified && line_text != original_line_text
      # Gestione della dimensione della cache
      @replacement_cache.shift if @replacement_cache.size >= self.class::CACHE_SIZE_LIMIT
      @replacement_cache[original_line_text] = line_text

      # Aggiorna il testo nell'editor
      @text.delete(line_start, 'insert')
      @text.insert(line_start, line_text)
      
      # Mostra la notifica appropriata
      if word_replaced && space_added
        show_replacement_notification("sostituita parola - inserito spazio")
      elsif word_replaced
        show_replacement_notification("sostituita parola")
      elsif space_added
        show_replacement_notification("inserito spazio")
      end
    end
  end

  def replace_with_punctuation_for_period
    # Metodo specifico per gestire le sostituzioni prima del punto
    current_pos = @text.index('insert')
    line_start = "#{current_pos.split('.').first}.0"
    line_text = @text.get(line_start, 'insert')

    # Controlla se il testo è già nella cache
    return false if @replacement_cache.key?(line_text)

    # Salva il testo originale per confronto
    original_line_text = line_text.dup
    modified = false

    # Esegui le sostituzioni per le parole che precedono il punto
    @replacements.each do |wrong, correct|
      # Cerca parole che finiscono alla fine della riga (prima del punto che stiamo per inserire)
      if line_text.match?(/\b#{Regexp.escape(wrong)}\s*$/)
        line_text.gsub!(/\b#{Regexp.escape(wrong)}\s*$/, correct)
        modified = true
        break # Ferma alla prima sostituzione trovata
      end
    end

    # Se sono state fatte modifiche, aggiorna la cache e il testo
    if modified && line_text != original_line_text
      # Gestione della dimensione della cache
      @replacement_cache.shift if @replacement_cache.size >= CACHE_SIZE_LIMIT
      @replacement_cache[original_line_text] = line_text

      # Aggiorna il testo nell'editor
      @text.delete(line_start, 'insert')
      @text.insert(line_start, line_text)
      
      # Mostra notifica per la parola sostituita
      show_replacement_notification("sostituita parola")
      return true
    end
    
    return false
  end

  def apply_replacements(text)
    result = text.dup
    @replacements.each do |wrong, correct|
      # Cerca solo la parola esatta, seguita da spazio/punteggiatura/fine linea
      result.gsub!(/(^|\s)#{Regexp.escape(wrong)}($|\s|[,;:.!?])/) do |match|
        match.gsub(wrong, correct)
      end
    end
    result
  end

  def update_text_and_cache(line_start, original_text, new_text)
    @replacement_cache.shift if @replacement_cache.size >= CACHE_SIZE_LIMIT
    @replacement_cache[original_text] = new_text

    @text.delete(line_start, 'insert')
    @text.insert(line_start, new_text)
    
    # Mostra notifica per la parola sostituita
    show_replacement_notification("sostituita parola")
  end

  def get_available_fonts
    system_fonts = TkFont.families
    # Filtra i font simbolici (escludi quelli che iniziano con "@" o hanno nomi strani)
    system_fonts.reject { |font| font.start_with?('@') || font.downcase.include?('symbol') }
  end

  def change_font(font_name)
    @text.configure('font' => TkFont.new('family' => font_name, 'size' => 16))
    @current_font_name = font_name
    update_window_title
  end

  def cut_text
    begin
      # Salva il testo selezionato nella clipboard
      if @text.tag_ranges('sel').any?
        text_to_cut = @text.get('sel.first', 'sel.last')
        TkClipboard.clear
        TkClipboard.append(text_to_cut)
        # Elimina il testo selezionato
        @text.delete('sel.first', 'sel.last')
      end
    rescue StandardError => e
      puts "Errore nel tagliare il testo: #{e.message}"
    end
  end

  def copy_text
    begin
      # Copia il testo selezionato nella clipboard
      if @text.tag_ranges('sel').any?
        text_to_copy = @text.get('sel.first', 'sel.last')
        TkClipboard.clear
        TkClipboard.append(text_to_copy)
      end
    rescue StandardError => e
      puts "Errore nel copiare il testo: #{e.message}"
    end
  end
  
  def paste_text
    begin
      # Incolla il testo dalla clipboard
      clipboard_content = TkClipboard.get
      if @text.tag_ranges('sel').any?
        # Se c'è una selezione, sostituiscila con il contenuto della clipboard
        @text.delete('sel.first', 'sel.last')
      end
      @text.insert('insert', clipboard_content)
    rescue StandardError => e
      puts "Errore nell'incollare il testo: #{e.message}"
    end
  end

  def show_abbreviations_window
    # Crea una nuova finestra
    window = TkToplevel.new(@root)
    window.title = "Elenco Sostituzioni"
    window.geometry("400x600")

    frame = TkFrame.new(window) { pack(fill: 'both', expand: true) }

    text_widget = TkText.new(frame) do
      wrap 'word'
      state 'normal'
      font TkFont.new('family' => 'Courier', 'size' => 12)
      pack(fill: 'both', expand: true)
    end

    scrollbar = TkScrollbar.new(frame) do
      orient 'vertical'
      command proc { |*args| text_widget.yview(*args) }
      pack(side: 'right', fill: 'y')
    end

    text_widget.yscrollcommand(proc { |first, last| scrollbar.set(first, last) })

    # Carica il file replacements.txt e lo mostra
    if File.exist?('replacements.txt')
      File.foreach('replacements.txt') do |line|
        abbrev, full = line.chomp.split(' ', 2)
        text_widget.insert('end', "#{abbrev} → #{full}\n") if abbrev && full
      end
    else
      text_widget.insert('end', "File replacements.txt non trovato.")
    end

    text_widget.configure(state: 'disabled') # Rende il testo non modificabile

    # Bottone per chiudere
    TkButton.new(window) do
      text 'Chiudi'
      command { window.destroy }
      pack(pady: 10)
    end
  end

  # NUOVO METODO per aggiornare il titolo della finestra
  def update_window_title
    base_title = "Word Processor by Giuseppe Bassan e AI"

    # Ottieni il nome del file se disponibile
    file_part = if @file_path && !@file_path.empty?
                  " - #{File.basename(@file_path)}"
                else
                  ""
                end

    # Ottieni il font corrente
    current_font = @text.cget('font')
    font_name = current_font.actual('family')
    font_part = " - [#{font_name}]"

    # Componi il titolo completo
    full_title = "#{base_title}#{file_part}#{font_part}"
    @root.title(full_title)
  end

  def show_replacement_notification(message)
  @notification_sound.play_sound if @sound_enabled

  # Distruggi la notifica precedente se esiste
  @replacement_notification.destroy if @replacement_notification

  begin
    # Ottieni la posizione del cursore
    cursor_pos = @text.index('insert')
    cursor_bbox = @text.bbox(cursor_pos)

    # Controllo più robusto per cursor_bbox
    unless cursor_bbox && cursor_bbox.is_a?(Array) && cursor_bbox.length >= 4
      puts "Debug: cursor_bbox non disponibile o non valido: #{cursor_bbox.inspect}"
      return # Esce silenziosamente se non può ottenere la posizione
    end

    # Verifica che tutti gli elementi siano numerici
    unless cursor_bbox.all? { |element| element.is_a?(Numeric) }
      puts "Debug: cursor_bbox contiene elementi non numerici: #{cursor_bbox.inspect}"
      return
    end

    # Calcola le coordinate assolute con controlli aggiuntivi
    text_x = @text.winfo_rootx + cursor_bbox[0].to_i
    text_y = @text.winfo_rooty + cursor_bbox[1].to_i - 30 # 30 pixel sopra il cursore

    # Verifica che le coordinate siano valide
    if text_x < 0 || text_y < 0
      puts "Debug: coordinate negative, utilizzo posizione di fallback"
      text_x = @text.winfo_rootx + 50
      text_y = @text.winfo_rooty + 50
    end

    # Crea la finestra di notifica
    @replacement_notification = TkToplevel.new do
      overrideredirect true
      geometry "+#{text_x}+#{text_y}"
    end

    # Frame contenitore con bordo
    frame = TkFrame.new(@replacement_notification) do
      relief 'solid'
      borderwidth 1
      background 'lightgreen'
      pack(padx: 2, pady: 2)
    end

    # Label con il messaggio
    TkLabel.new(frame) do
      text message
      background 'lightgreen'
      font TkFont.new('family' => 'Arial', 'size' => 10, 'weight' => 'bold')
      foreground 'darkgreen'
      pack(anchor: 'w', padx: 8, pady: 4)
    end

    # Programma la distruzione dopo 1 secondo
    Tk.after(1000) do
      begin
        @replacement_notification.destroy if @replacement_notification
        @replacement_notification = nil
      rescue StandardError => e
        puts "Debug: errore nella distruzione della notifica: #{e.message}"
        @replacement_notification = nil
      end
    end

  rescue StandardError => e
    puts "Debug: errore in show_replacement_notification: #{e.message}"
    # Ripulisci eventuali riferimenti
    @replacement_notification = nil
    # Non rilancia l'errore per non interrompere il flusso del programma
  end
end

  #----- GRAMMAR CHECK ---------------------------------------------------

  def start_grammar_check_thread
    return if @grammar_check_thread_running
    
    @grammar_check_thread_running = true
    @grammar_check_thread = Thread.new do
      loop do
        sleep 3  # Aumentato a 3 secondi per ridurre il carico
        
        # Controlla se il thread deve continuare
        break unless @grammar_check_thread_running
        
        # Esegui il controllo solo se abilitato
        if @grammar_check_enabled
          begin
            check_grammar
          rescue StandardError => e
            puts "Errore nel controllo grammaticale: #{e.message}"
          end
        end
      end
    end
  end

  def check_grammar
    return unless @grammar_check_enabled
    
    # Ottieni il testo corrente
    text = @text.get('1.0', 'end')
    
    # Limita il controllo automatico per evitare rallentamenti
    if text.bytesize > MAX_GRAMMAR_CHECK_SIZE
      puts "Documento troppo grande (#{text.bytesize} bytes) per controllo automatico"
      return
    end
    
    # Rimuovi tutti i tag di errore esistenti PRIMA di iniziare il controllo
    Tk.after(0) { remove_all_error_tags }
    
    # Controlla la grammatica
    errors = @grammar_checker.check_text(text)
    return if errors.empty?

    # Calcola TUTTE le posizioni in un singolo passaggio
    error_positions = calculate_all_error_positions(text, errors)
    
    # Applica i tag nella GUI thread
    Tk.after(0) do
      apply_error_tags(error_positions)
    end
  end

  def remove_all_error_tags
    begin
      # Rimuovi il tag generico 'error'
      @text.tag_remove('error', '1.0', 'end') if @text
      
      # Rimuovi tutti i tag specifici degli errori
      if @error_tags && !@error_tags.empty?
        @error_tags.each do |tag|
          begin
            @text.tag_remove(tag, '1.0', 'end') if @text
            @text.tag_delete(tag) if @text
          rescue StandardError => e
            puts "Errore nella rimozione del tag #{tag}: #{e.message}"
          end
        end
        @error_tags.clear
      end
      @error_tag_counter = 0
      
    rescue StandardError => e
      puts "Errore nella rimozione dei tag: #{e.message}"
    end
  end

  def show_error_tooltip(event, message, suggestions)
    @tooltip.destroy if @tooltip

    @tooltip = TkToplevel.new do
      overrideredirect true
      geometry "+#{event.x_root + 10}+#{event.y_root + 20}"
    end

    # Frame contenitore con bordo
    frame = TkFrame.new(@tooltip) do
      relief 'solid'
      borderwidth 1
      background 'lightyellow'
      pack(padx: 2, pady: 2)
    end

    # Messaggio di errore
    TkLabel.new(frame) do
      text message
      background 'lightyellow'
      font TkFont.new('family' => 'Arial', 'size' => 10, 'weight' => 'bold')
      pack(anchor: 'w', padx: 5, pady: 2)
    end

    # Suggerimenti (solo se ci sono)
    unless suggestions.empty?
      TkLabel.new(frame) do
        text "Suggerimenti: #{suggestions.join(', ')}"
        background 'lightyellow'
        font TkFont.new('family' => 'Arial', 'size' => 9)
        foreground 'darkblue'
        pack(anchor: 'w', padx: 5, pady: 2)
      end
    end
  end

  def hide_error_tooltip
    @tooltip.destroy if @tooltip
    @tooltip = nil
  end

  def check_selected_grammar
    selection = @text.tag_ranges('sel')
    if selection.empty?
      Tk.messageBox(icon: 'warning', type: 'ok', message: 'Seleziona del testo da controllare.')
      return
    end

    # Disabilita temporaneamente il controllo automatico
    auto_check_was_enabled = @grammar_check_enabled
    @grammar_check_enabled = false
    
    # Rimuovi evidenziazioni precedenti
    remove_all_error_tags
    
    selected_text = @text.get('sel.first', 'sel.last')
    
    # Controlla dimensione
    if selected_text.bytesize > MAX_GRAMMAR_CHECK_SIZE
      Tk.messageBox(icon: 'warning', type: 'ok', 
                   message: "Testo selezionato troppo grande (#{selected_text.bytesize} bytes).")
      @grammar_check_enabled = auto_check_was_enabled
      return
    end
    
    errors = @grammar_checker.check_text(selected_text)
    
    if errors.empty?
      Tk.messageBox(icon: 'info', type: 'ok', message: 'Nessun errore trovato nella selezione.')
      @grammar_check_enabled = auto_check_was_enabled
      return
    end

    # Ottieni la posizione base della selezione
    base_index = @text.index('sel.first')
    base_line, base_col = base_index.split('.').map(&:to_i)
    
    # Usa il metodo ottimizzato con le coordinate base corrette
    error_positions = calculate_all_error_positions(selected_text, errors, base_line, base_col)
    
    @grammar_check_enabled = true  # Riabilita PRIMA di chiamare apply_error_tags
    apply_error_tags(error_positions)
    
    # Riabilita controllo automatico
    @grammar_check_enabled = auto_check_was_enabled
  end
  
  def cleanup_and_exit
    stop_grammar_check_thread
    stop_languagetool_server
    exit
  end

  def stop_grammar_check_thread
    @grammar_check_thread_running = false
    if @grammar_check_thread && @grammar_check_thread.alive?
      @grammar_check_thread.kill
      @grammar_check_thread = nil
    end
  end  

  def calculate_all_error_positions(text, errors, base_line = 1, base_col = 0)
    # Mappa tutti gli offset
    offsets_to_find = {}
    errors.each_with_index do |error, i|
      start_offset = error[:position]
      end_offset = error[:position] + error[:length]
      
      offsets_to_find[start_offset] ||= []
      offsets_to_find[start_offset] << { type: :start, index: i, error: error }
      
      offsets_to_find[end_offset] ||= []
      offsets_to_find[end_offset] << { type: :end, index: i, error: error }
    end

    error_positions = Array.new(errors.length) { {} }
    
    # Singolo passaggio - parte dalle coordinate base
    line = base_line
    col = base_col
    
    text.each_char.with_index do |char, offset|
      if positions = offsets_to_find[offset]
        tk_pos = "#{line}.#{col}"
        positions.each do |pos_info|
          error_index = pos_info[:index]
          if pos_info[:type] == :start
            error_positions[error_index][:start_pos] = tk_pos
            error_positions[error_index][:error] = pos_info[:error]
          else # :end
            error_positions[error_index][:end_pos] = tk_pos
          end
        end
      end

      # Aggiorna coordinate
      if char == "\n"
        line += 1
        col = 0
      else
        col += 1
      end
    end
    
    # Gestisce errori alla fine
    if positions = offsets_to_find[text.length]
      tk_pos = "#{line}.#{col}"
      positions.each do |pos_info|
        if pos_info[:type] == :end
          error_positions[pos_info[:index]][:end_pos] = tk_pos
        end
      end
    end

    error_positions.compact
  end

  def apply_error_tags(error_positions)
    return unless @grammar_check_enabled  # Doppio controllo
    
    @error_tag_counter = 0
    @error_tags ||= []
    
    error_positions.each do |error_pos|
      next unless error_pos[:start_pos] && error_pos[:end_pos]
      
      @error_tag_counter += 1
      error_tag = "error_#{@error_tag_counter}"
      error_data = error_pos[:error]

      begin
        # Configura e applica il tag
        @text.tag_configure(error_tag, underline: true, foreground: 'red')
        @text.tag_add(error_tag, error_pos[:start_pos], error_pos[:end_pos])

        # Associa eventi per tooltip
        @text.tag_bind(error_tag, 'Enter') do |e|
          show_error_tooltip(e, error_data[:message], error_data[:suggestions])
        end

        @text.tag_bind(error_tag, 'Leave') do
          hide_error_tooltip
        end

        @error_tags << error_tag
        
      rescue StandardError => e
        puts "Errore nell'applicazione del tag #{error_tag}: #{e.message}"
      end
    end
  end

  #----- GEMINI AI -------------------------------------------------------

  def generate_content(prompt)
    # Funzione per generare contenuto con HTTPX verso API Gemini
    url = "#{@gemini_api_url_base}?key=#{@gemini_api_key}"

    response = HTTPX.post(url, json: {
      "contents" => [{ "parts" => [{ "text" => prompt }] }]
    })

    case response.status
    when 200
      data = JSON.parse(response.body)
      text = data.dig("candidates", 0, "content", "parts", 0, "text") || "Risposta vuota!"
      # Rimuovi gli asterischi
      text.gsub!('*', '')
      return text
    
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

  def show_waiting_message(title, message)
    # Metodo per mostrare un messaggio di attesa
    dialog = TkToplevel.new(@root)
    dialog.title = title
    dialog.transient(@root)  # Rende il dialogo modale rispetto alla finestra principale
 
    # Calcola la posizione per centrare il dialogo
    window_width = 340
    window_height = 110

    # Ottieni le dimensioni dello schermo in modo sicuro
    begin
      x = (@root.winfo_width / 2) - (window_width / 2) + @root.winfo_x
      y = (@root.winfo_height / 2) - (window_height / 2) + @root.winfo_y
    rescue
      # Fallback se non possiamo ottenere le dimensioni
      x = 400
      y = 300
    end

    dialog.geometry("#{window_width}x#{window_height}+#{x}+#{y}")
    dialog.resizable(false, false)  # Blocca il ridimensionamento

    # Crea un frame contenitore
    frame = TkFrame.new(dialog)
    frame.pack(fill: 'both', expand: true, padx: 20, pady: 20)

    # Aggiungi una label con il messaggio
    label = TkLabel.new(frame) do
      text message
      font TkFont.new('family' => 'Arial', 'size' => 12)
      pack(pady: 10)
    end

    # Aggiungi un indicatore di progresso
    progress_text = TkLabel.new(frame) do
      text "●●●"
      font TkFont.new('family' => 'Arial', 'size' => 14)
      foreground 'blue'
      pack(pady: 5)
    end

    # Animazione dei puntini
    animate_dots(progress_text)
 
    # Gestisce la chiusura forzata
    dialog.protocol("WM_DELETE_WINDOW") do
      # Non fare nulla - impedisce all'utente di chiudere manualmente
    end

    return dialog
  end

  def animate_dots(label)
    # Metodo per animare i puntini di attesa
    @animation_stopped = false

    @animation_thread = Thread.new do
      dots = ["●○○", "○●○", "○○●", "●●○", "○●●", "●○●"]
      index = 0
  
      until @animation_stopped
        Tk.after(0) do
          begin
            label.configure('text' => dots[index % dots.length]) if label
          rescue StandardError => e
            # Ignora errori se il label non esiste più
          end
        end
    
        index += 1
        sleep 0.5
      end
    end

    # Assicurati che il thread venga terminato quando non è più necessario
    label.bind("Destroy") do
      @animation_stopped = true
      @animation_thread.kill if @animation_thread && @animation_thread.alive?
    end
  end

  #----- THREAD E SALVATAGGIO --------------------------------------------

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

  def play_sound(key)
    return unless @sound_enabled
    return if %w[Shift_L Shift_R Control_L Control_R Alt_L ISO_Level3_Shift].include?(key)

    @sound_player.play_sound
  end

  def start_languagetool_server
    puts "Avvio del server LanguageTool..."
    command = "java -Xmx2G -Xms512M -XX:+UseG1GC -cp '/usr/share/languagetool/*' org.languagetool.server.HTTPServer --port 8081"

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

class SoundPlayer
  def initialize(sound_file)
    @sound_file = sound_file
    @sound_enabled = File.exist?(sound_file)
    
    if @sound_enabled
      # Precarica il file in memoria
      @sound_data = File.read(sound_file)
      puts "Sound file preloaded: #{File.size(sound_file)} bytes"
    else
      puts "Sound file not found: #{sound_file}"
    end
  rescue StandardError => e
    puts "Failed to load sound: #{e.message}"
    @sound_enabled = false
  end

  def play_sound
    return unless @sound_enabled
    spawn("aplay '#{@sound_file}' >/dev/null 2>&1")
  end
end

# Avvio Applicazione
WordProcessor.new
Tk.mainloop
